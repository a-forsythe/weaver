#!/usr/bin/env bash
# Used in the CI workflow to publish new releases to the private NPM package registry
# associated with this GitHub repo, configured via the registry details in .npmrc and
# authorized via the CI job's GITHUB_TOKEN value, which is supplied to this script as
# NODE_AUTH_TOKEN.
#
# If this script is run from any branch other than 'main', or if the contents of the
# package produced by 'npm pack' have not changed since the last time a release was
# published, the script will exit successfully without doing anything.
#
# When a new package is published, this script will automatically bump the version in
# package.json and tag a new release. These version numbers use semantic versioning,
# i.e. MAJOR.MINOR.PATCH.
#
# Suppose we're at v1.2.3, and the shasum for our package has changed from the v1.2.3
# package that's published to the GitHub registry, and we're running this script in
# main. The resulting version bump depends on the summary lines in the descriptions for
# those intervening commits:
#
# - If any commit includes 'BREAKING' in the summary line, we'll get:
#     chore(npm): Release v2.0.0
#
# - If any commit description begins with 'feat:' or 'feat(*):', we'll get:
#     chore(npm): Release v1.3.0
#
# - Otherwise, we'll get:
#     chore(npm): Release v1.2.4

exit_with_error() {
    echo -e "\033[0;91mERROR: $1\033[0m" >&2
    exit 1
}

exit_without_version_bump() {
    echo "$1; nothing to publish." >&2
    echo ""
    exit 0
}

print_status() {
    echo "$1" >&2
}

# Require an auth token, validate that we have a valid dist build + required tools
[ "$NODE_AUTH_TOKEN" != "" ] || exit_with_error "NODE_AUTH_TOKEN is not set"
[ -f dist/index.js ] || exit_with_error "Package not built to dist; try 'npm run build'"
which jq >/dev/null || exit_with_error "jq is not installed"

# Verify that our working directory is clean and git is configured
[ "$(git status --porcelain)" == "" ] || exit_with_error "working directory is not clean"
if [ "$(git config user.name)" == "" ] || [ "$(git config user.email)" == "" ]; then
    exit_with_error "git user.name and user.email are not configured"
fi

# If we don't have the main branch checked out, write nothing to stdout and exit with 0
# (indicating that there's simply nothing to publish)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$GIT_BRANCH" != "main" ]; then
    exit_without_version_bump "Not in 'main' branch (HEAD is $GIT_BRANCH)"
fi

set -e

# Parse the package name and current version from package.json
PACKAGE_NAME=$(jq -er '.name' package.json)
CURRENT_VERSION=$(jq -er '.version' package.json)
print_status "$PACKAGE_NAME: $CURRENT_VERSION"

# Use npm show to get the shasum of the package currently published at that version,
# if any, and parse the output from npm pack to get the shasum of the package as it
# exists on disk
REMOTE_SHASUM=$(npm show "$PACKAGE_NAME@$PACKAGE_VERSION" dist.shasum 2>/dev/null | cat)
LOCAL_SHASUM=$(npm pack --dry-run 2>&1 | grep -E '^npm [a-z]+ shasum:\s+[0-9a-f]{40}' | awk '{print $NF}')
[ "$LOCAL_SHASUM" != "" ] || exit_with_error "Failed to parse shasum value from 'npm pack' output"
print_status "Remote shasum for $CURRENT_VERSION: $REMOTE_SHASUM"
print_status "  Local shasum at $CURRENT_VERSION: $LOCAL_SHASUM"

# If there have been no changes to the client package since the last release, we're done
if [ "$LOCAL_SHASUM" == "$REMOTE_SHASUM" ]; then
    exit_without_version_bump "dist/ is unchanged from latest release"
fi

# Otherwise, we need to bump the version number and create a new release: any
# significant change is treated as a hotfix that bumps the patch version
VERSION_BUMP="patch"

# We need to figure out when the version number in package.json last changed so
# we can examine the commits between the head revision and the most recent release
VERSION_LINE_NO=$(grep -En '^\s+"version": "' package.json | cut -d ':' -f 1)
if [ "$VERSION_LINE_NO" != "" ]; then
    print_status "version number is on line $VERSION_LINE_NO of package.json"
else
    exit_with_error "Couldn't find version line number in package.json"
fi

LAST_RELEASE_SHA=$(git --no-pager blame --line-porcelain -L"$VERSION_LINE_NO,+1" -- package.json | head -n 1 | cut -d ' ' -f 1)
if [ "$LAST_RELEASE_SHA" != "" ]; then
    print_status "git blame for line $VERSION_LINE_NO shows version last changed at $LAST_RELEASE_SHA"
else
    exit_with_error "Couldn't get commit hash of last change to 'version' in package.json"
fi

# Now we can examine the summary lines for each intervening commit description: if
# 'BREAKING' appears, we'll bump the major version; if any commits are prefixed with
# 'feat:' or 'feat(*):' we'll bump the minor version; otherwise we'll bump the patch
# version
NUM_BREAKING_COMMITS=$(git --no-pager log --pretty=format:%s "$LAST_RELEASE_SHA..HEAD" | grep -Fc 'BREAKING' | cat)
print_status "Num 'BREAKING' commits since last release: $NUM_BREAKING_COMMITS"
if [ "$NUM_BREAKING_COMMITS" -gt 0 ]; then
    VERSION_BUMP="major"
else
    # Check for commit messages prefixed 'feat:' or 'feat(*):'
    NUM_FEAT_COMMITS=$(git --no-pager log --pretty=format:%s "$LAST_RELEASE_SHA..HEAD" | grep -Ec '^feat(\(.*\))?:' | cat)
    print_status "Num 'feat:' or 'feat(*):' commits since last release: $NUM_FEAT_COMMITS"
    if [ "$NUM_FEAT_COMMITS" -gt 0 ]; then
        VERSION_BUMP="minor"
    fi
fi

# Now we can execute our version bump, which updates package.json etc. in place,
# commits that change, and tags it with the version number
COMMIT_MESSAGE="chore(npm): Release v%s"
print_status "Bumping $VERSION_BUMP version and committing change to package.json..."
npm version $VERSION_BUMP -m "$COMMIT_MESSAGE"

# With the version number updated, we can publish the package to GitHub
print_status "Publishing $PACKAGE_NAME to GitHub registry..."
npm publish

# If that succeeded, we want to push the package.json change, and we're done
print_status "Pushing version bump commit (with tags)..."
git push --follow-tags

print_status "OK."
