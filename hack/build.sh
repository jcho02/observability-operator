# To push to your own registry, override the REGISTRY and NAMESPACE env vars,
# i.e:
#   $ REGISTRY=quay.io NAMESPACE=yourusername ./hack/build.sh
#
# REQUIREMENTS:
#  * a valid login session to a container registry.
#  * `docker`
#  * `jq`
#  * `yq`
#  * `opm`
#  * `skopeo`

set -e

export OPERATOR_NAME='observability-operator'
export REGISTRY=${REGISTRY:-'quay.io'}
export NAMESPACE=${NAMESPACE:-'rhobs'}
export TAG=${TAG:-'0.0.23'}
export CSV_PATH=${CSV_PATH:-'bundle/manifests/observability-operator.clusterserviceversion.yaml'}
export ANNOTATIONS_PATH=${ANNOTATIONS_PATH:-'bundle/metadata/annotations.yaml'}

function cleanup {
	# shellcheck disable=SC2046
	if [ -x $(command -v git >/dev/null 2>&1) ]; then
		git checkout "${CSV_PATH}" >/dev/null 2>&1
		git checkout "${ANNOTATIONS_PATH}" >/dev/null 2>&1
	fi
}

trap cleanup EXIT

# prints pre-formatted info output.
function info {
	echo "INFO $(date '+%Y-%m-%dT%H:%M:%S') $*"
}

# prints pre-formatted error output.
function error {
	>&2 echo "ERROR $(date '+%Y-%m-%dT%H:%M:%S') $*"
}

function digest() {
	declare -n ret=$2
	IMAGE=$1
	docker pull "${IMAGE}"
	# shellcheck disable=SC2034
	ret=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}")
}

docker buildx build --push --platform "linux/amd64,linux/ppc64le" -f build/Dockerfile -t "${REGISTRY}/${NAMESPACE}/observability-operator:${TAG}" .
digest "${REGISTRY}/${NAMESPACE}/observability-operator:${TAG}" OPERATOR_DIGEST

# need exporting so that yq can see them
export OPERATOR_DIGEST

# prepare operator files, then build and push operator bundle and catalog
# index images.

yq eval -i '
	.metadata.name = strenv(OPERATOR_NAME) |
	.metadata.annotations.version = strenv(TAG) |
	.metadata.annotations.containerImage = strenv(OPERATOR_DIGEST) |
	.metadata.labels += {"operatorframework.io/arch.amd64": "supported", "operatorframework.io/arch.ppc64le": "supported", "operatorframework.io/os.linux": "supported"} |
	del(.spec.replaces) |
	.spec.install.spec.deployments[0].name = strenv(OPERATOR_NAME) |
	.spec.install.spec.deployments[0].spec.template.spec.containers[0].image = strenv(OPERATOR_DIGEST)
	' "${CSV_PATH}"

yq eval -i '
	.annotations."operators.operatorframework.io.bundle.channel.default.v1" = "test" |
	.annotations."operators.operatorframework.io.bundle.channels.v1" = "test"
	' "${ANNOTATIONS_PATH}"

make bundle-image

AMD64_DIGEST=$(skopeo inspect --raw  docker://${REGISTRY}/${NAMESPACE}/observability-operator-bundle:${TAG} | \
               jq -r '.manifests[] | select(.platform.architecture == "amd64" and .platform.os == "linux").digest')
POWER_DIGEST=$(skopeo inspect --raw  docker://${REGISTRY}/${NAMESPACE}/observability-operator-bundle:${TAG} | \
               jq -r '.manifests[] | select(.platform.architecture == "ppc64le" and .platform.os == "linux").digest')

opm index add --build-tool docker --bundles "${REGISTRY}/${NAMESPACE}/observability-operator-bundle@${AMD64_DIGEST}" --tag "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-amd64" --binary-image "quay.io/operator-framework/opm:v1.28.0-amd64"
docker push "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-amd64"
opm index add --build-tool docker --bundles "${REGISTRY}/${NAMESPACE}/observability-operator-bundle@${POWER_DIGEST}" --tag "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-ppc64le" --binary-image "quay.io/operator-framework/opm:v1.28.0-ppc64le"
docker push "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-ppc64le"

docker manifest create --amend "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}" \
	"${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-amd64" \
	"${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}-ppc64le"
docker manifest push "${REGISTRY}/${NAMESPACE}/observability-operator-catalog:${TAG}"
