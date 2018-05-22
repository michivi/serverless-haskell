#!/bin/sh
# Test packaging a function, deploying it to AWS and running it. With --dry-run,
# only packaging is tested. With --no-docker, Docker isn't used for packaging.

set -e

DOCKER=true
while [ $# -gt 0 ]
do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-docker)
            DOCKER=false
            shift
            ;;
        *)
            shift
            ;;
    esac
done

for DEPENDENCY in curl jq npm pwgen stack
do
    which $DEPENDENCY >/dev/null || \
        (echo "$DEPENDENCY is required for the test." >&2; exit 1)
done

# Root directory of the repository
DIST=$(cd $(dirname $0)/..; echo $PWD)

# Directory with the test project skeleton
SKELETON=$(cd $(dirname $0)/skeleton; echo $PWD)

# Directory with the expected outputs
EXPECTED=$(cd $(dirname $0)/expected; echo $PWD)

# Stackage resolver to use. LTS 11 cannot be used due to missing amazonka:
# https://github.com/seek-oss/serverless-haskell/issues/34
RESOLVER=$(curl -s https://www.stackage.org/download/snapshots.json | \
               jq -r '."lts-10"')

# Temporary directory to create a project in
DIR=$(mktemp -d)
echo "Testing in $DIR"
if $DRY_RUN
then
    trap "rm -rf $DIR" EXIT
else
    trap "(sls --no-color remove || true); rm -rf $DIR" EXIT
fi
cd $DIR

NAME=s-h-test-$(pwgen 10 -0 -A)

# Copy the test files over, replacing the values
SED="sed s!NAME!$NAME!g;s!DIST!$DIST!g;s!RESOLVER!$RESOLVER!g;s!DOCKER!$DOCKER!g"
for FILE in $(find $SKELETON -type f | grep -v /\\. | sed "s!$SKELETON/!!")
do
    mkdir -p $(dirname $FILE)
    $SED < $SKELETON/$FILE > $FILE
done

export PATH=$(npm bin):$PATH

# Install Serverless and deploy the project
npm install serverless
npm install $DIST/serverless-plugin

if [ "$DRY_RUN" = "true" ]
then
    sls package
    echo "Packaging verified."
else
    sls deploy

    # Run the function and verify the results
    sls invoke --function main --data '[4, 5, 6]' > output.json

    diff $EXPECTED/output.json output.json && echo "Expected result verified."

    # Run the function from the subdirectory and verify the result
    sls invoke --function subdir --data '{}' > subdir_output.json

    diff $EXPECTED/subdir_output.json subdir_output.json && \
        echo "Expected result verified from subdir function."

    # Wait for the logs to be propagated and verify them, ignoring volatile request
    # IDs and extra blank lines
    sleep 10
    sls logs --function main | grep -v RequestId | grep -v '^\W*$' > logs.txt

    diff $EXPECTED/logs.txt logs.txt && echo "Expected output verified."
fi
