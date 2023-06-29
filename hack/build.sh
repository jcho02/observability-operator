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
export TAG=${TAG:-'0.0.22'}

docker buildx build --push --platform "linux/amd64,linux/ppc64le" -f build/Dockerfile -t "${REGISTRY}/${NAMESPACE}/observability-operator:${TAG}" .
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
