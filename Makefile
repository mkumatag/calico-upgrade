.PHONY: all binary test clean help
default: help
test: test-containerized                             ## Run all the tests
all: dist/calico-upgrade dist/calico-upgrade-darwin-amd64 dist/calico-upgrade-windows-amd64.exe

###############################################################################
# Go Build versions
GO_BUILD_VER:=v0.16
CALICO_BUILD?=calico/go-build:$(GO_BUILD_VER)

###############################################################################
# Version directory
CALICO_UPGRADE_DIR=$(dir $(realpath $(lastword $(MAKEFILE_LIST))))
VERSIONS_FILE?=$(CALICO_UPGRADE_DIR)../_data/versions.yml

# Now use ?= to allow the versions derived from versions.yml to be
# overriden (by the environment).
CALICOCTL_VER?=master
CALICOCTL_V2_VER?=v1.6.x-series
K8S_VERSION?=v1.10.4
ETCD_VER?=v3.3.7

# Construct the calico/ctl names we'll use to download calicoctl and extract the
# binaries.
$(info $(shell printf "%-21s = %-10s\n" "CALICOCTL_VER" $(CALICOCTL_VER)))
$(info $(shell printf "%-21s = %-10s\n" "CALICOCTL_V2_VER" $(CALICOCTL_V2_VER)))
CTL_CONTAINER_NAME?=calico/ctl:$(CALICOCTL_VER)
CTL_CONTAINER_V2_NAME?=calico/ctl:$(CALICOCTL_V2_VER)
KUBECTL_URL=https://dl.k8s.io/$(K8S_VERSION)/kubernetes-client-linux-amd64.tar.gz

###############################################################################
# calico-upgrade build
# - Building the calico-upgrade binary in a container
# - Building the calico-upgrade binary outside a container ("simple-binary")
# - Building the calico/upgrade image
###############################################################################
# Determine which OS / ARCH.
OS := $(shell uname -s | tr A-Z a-z)
ARCH := amd64

GIT_VERSION?=$(shell git describe --tags --dirty --always)
CALICO_UPGRADE_DIR=pkg
CALICO_UPGRADE_CONTAINER_NAME?=calico/upgrade
CALICO_UPGRADE_FILES=$(shell find $(CALICO_UPGRADE_DIR) -name '*.go')
CALICO_UPGRADE_CONTAINER_CREATED=$(CALICO_UPGRADE_DIR)/.calico_upgrade.created

CALICO_UPGRADE_BUILD_DATE?=$(shell date -u +'%FT%T%z')
CALICO_UPGRADE_GIT_REVISION?=$(shell git rev-parse --short HEAD)

LOCAL_USER_ID?=$(shell id -u $$USER)

PACKAGE_NAME?=github.com/projectcalico/calico-upgrade

CALICO_UPGRADE_VERSION ?= $(GIT_VERSION)
LDFLAGS=-ldflags "-X $(PACKAGE_NAME)/pkg/commands.VERSION=$(CALICO_UPGRADE_VERSION) \
	-X $(PACKAGE_NAME)/pkg/commands.BUILD_DATE=$(CALICO_UPGRADE_BUILD_DATE) \
	-X $(PACKAGE_NAME)/pkg/commands.GIT_REVISION=$(CALICO_UPGRADE_GIT_REVISION) -s -w"

LIBCALICOGO_PATH?=none

# curl should failed on 404
CURL=curl -sSf

calico/upgrade: $(CALICO_UPGRADE_CONTAINER_CREATED)      ## Create the calico/upgrade image

.PHONY: clean-calico-upgrade
clean-calico-upgrade:
	docker rmi $(CALICO_UPGRADE_CONTAINER_NAME):latest || true

# Use this to populate the vendor directory after checking out the repository.
# To update upstream dependencies, delete the glide.lock file first.
vendor: glide.yaml
	# Ensure that the glide cache directory exists.
	mkdir -p $(HOME)/.glide

	# To build without Docker just run "glide install -strip-vendor"
	if [ "$(LIBCALICOGO_PATH)" != "none" ]; then \
          EXTRA_DOCKER_BIND="-v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro"; \
	fi; \
  docker run --rm \
    -v $(CURDIR):/go/src/$(PACKAGE_NAME):rw $$EXTRA_DOCKER_BIND \
    -v $(HOME)/.glide:/home/user/.glide:rw \
    -e LOCAL_USER_ID=$(LOCAL_USER_ID) \
    $(CALICO_BUILD) /bin/sh -c ' \
		  cd /go/src/$(PACKAGE_NAME) && \
      glide install -strip-vendor'

# build calico_upgrade image
$(CALICO_UPGRADE_CONTAINER_CREATED): pkg/Dockerfile.calico_upgrade dist/calico-upgrade dist/kubectl
	docker build -t $(CALICO_UPGRADE_CONTAINER_NAME) -f pkg/Dockerfile.calico_upgrade .
	touch $@

# Download kubectl instead of copying from hyperkube because it is 4x smaller
# this way
dist/kubectl:
	$(CURL) -L $(KUBECTL_URL) -o - | tar -zxvf - -C dist --strip-components=3
	chmod +x $(@D)/*


## Build calico-upgrade
binary: $(CALICO_UPGRADE_FILES) vendor
	# Don't try to "install" the intermediate build files (.a .o) when not on linux
	# since there are no write permissions for them in our linux build container.
	if [ "$(OS)" == "linux" ]; then \
		INSTALL_FLAG=" -i "; \
	fi; \
	GOOS=$(OS) GOARCH=$(ARCH) CGO_ENABLED=0 go build -v $$INSTALL_FLAG -o dist/calico-upgrade-$(OS)-$(ARCH) $(LDFLAGS) "./pkg/calicoupgrade.go"

dist/calico-upgrade: $(CALICO_UPGRADE_FILES) vendor
	$(MAKE) dist/calico-upgrade-linux-amd64
	mv dist/calico-upgrade-linux-amd64 dist/calico-upgrade

dist/calico-upgrade-linux-amd64: $(CALICO_UPGRADE_FILES) vendor
	$(MAKE) OS=linux ARCH=amd64 binary-containerized

dist/calico-upgrade-darwin-amd64: $(CALICO_UPGRADE_FILES) vendor
	$(MAKE) OS=darwin ARCH=amd64 binary-containerized

dist/calico-upgrade-windows-amd64.exe: $(CALICO_UPGRADE_FILES) vendor
	$(MAKE) OS=windows ARCH=amd64 binary-containerized
	mv dist/calico-upgrade-windows-amd64 dist/calico-upgrade-windows-amd64.exe

## Run the build in a container. Useful for CI
binary-containerized: $(CALICO_UPGRADE_FILES) vendor
	mkdir -p dist
	-mkdir -p .go-pkg-cache
	docker run --rm \
	  -e OS=$(OS) -e ARCH=$(ARCH) \
	  -e CALICO_UPGRADE_VERSION=$(CALICO_UPGRADE_VERSION) \
	  -e CALICO_UPGRADE_BUILD_DATE=$(CALICO_UPGRADE_BUILD_DATE) -e CALICO_UPGRADE_GIT_REVISION=$(CALICO_UPGRADE_GIT_REVISION) \
	  -v $(CURDIR):/go/src/$(PACKAGE_NAME):ro \
	  -v $(CURDIR)/dist:/go/src/$(PACKAGE_NAME)/dist \
    -e LOCAL_USER_ID=$(LOCAL_USER_ID) \
    -v $(CURDIR)/.go-pkg-cache:/go/pkg/:rw \
	  $(CALICO_BUILD) sh -c '\
	    cd /go/src/$(PACKAGE_NAME) && \
	    make OS=$(OS) ARCH=$(ARCH) \
	         CALICO_UPGRADE_VERSION=$(CALICO_UPGRADE_VERSION)  \
	         CALICO_UPGRADE_BUILD_DATE=$(CALICO_UPGRADE_BUILD_DATE) CALICO_UPGRADE_GIT_REVISION=$(CALICO_UPGRADE_GIT_REVISION) \
	         binary'

.PHONY: install
install:
	CGO_ENABLED=0 go install $(PACKAGE_NAME)/calico_upgrade

###############################################################################
# calico-upgrade UTs
###############################################################################
.PHONY: ut
## Run the Unit Tests locally
ut: dist/calico-upgrade
	# Run tests in random order find tests recursively (-r).
	ginkgo -cover -r --skipPackage vendor pkg/*

	@echo
	@echo '+==============+'
	@echo '| All coverage |'
	@echo '+==============+'
	@echo
	@find ./pkg/ -iname '*.coverprofile' | xargs -I _ go tool cover -func=_

	@echo
	@echo '+==================+'
	@echo '| Missing coverage |'
	@echo '+==================+'
	@echo
	@find ./pkg/ -iname '*.coverprofile' | xargs -I _ go tool cover -func=_ | grep -v '100.0%'

PHONY: test-containerized
## Run the tests in a container. Useful for CI, Mac dev.
test-containerized: dist/calico-upgrade
	docker run --rm -v $(CURDIR):/go/src/$(PACKAGE_NAME):rw \
    -e LOCAL_USER_ID=$(LOCAL_USER_ID) \
    $(CALICO_BUILD) sh -c 'cd /go/src/$(PACKAGE_NAME) && make ut'

## Perform static checks on the code. The golint checks are allowed to fail, the others must pass.
.PHONY: static-checks
static-checks: vendor
	# vet and errcheck are disabled since they find problems...
	docker run --rm \
		-e LOCAL_USER_ID=$(LOCAL_USER_ID) \
		-v $(CURDIR):/go/src/$(PACKAGE_NAME) \
		$(CALICO_BUILD) sh -c '\
			cd /go/src/$(PACKAGE_NAME) && \
			gometalinter --deadline=300s --disable-all --enable=goimports --vendor ./...'


SOURCE_DIR?=$(dir $(lastword $(MAKEFILE_LIST)))
SOURCE_DIR:=$(abspath $(SOURCE_DIR))
LOCAL_IP_ENV?=$(shell ip route get 8.8.8.8 | head -1 | awk '{print $$7}')
ST_TO_RUN?=tests/st/calico_upgrade/test_calico_upgrade.py
# Can exclude the slower tests with "-a '!slow'"
ST_OPTIONS?=

## Run the STs in a container
.PHONY: st
st: dist/calico-upgrade dist/calicoctl dist/calicoctlv2 run-etcd
	# Use the host, PID and network namespaces from the host.
	# Privileged is needed since 'calico node' write to /proc (to enable ip_forwarding)
	# Map the docker socket in so docker can be used from inside the container
	# All of code under test is mounted into the container.
	#   - This also provides access to calico-upgrade and the docker client
	docker run --net=host --privileged \
	           --uts=host \
	           --pid=host \
	           -e MY_IP=$(LOCAL_IP_ENV) \
	           --rm -ti \
                   -v /var/run/docker.sock:/var/run/docker.sock \
	           -v $(SOURCE_DIR):/code \
	           calico/test \
	           sh -c 'nosetests $(ST_TO_RUN) -sv --nologcapture  --with-xunit --xunit-file="/code/nosetests.xml" --with-timer $(ST_OPTIONS)'

	$(MAKE) stop-etcd

## Run etcd and a container for testing the upgrade binaries.  The dist directory will
## contain calico-upgrade and a v2.x and current v3.x versions of calicoctl.
.PHONY: st
testenv: dist/calico-upgrade dist/calicoctl dist/calicoctlv2 run-etcd
	-docker run --net=host --privileged \
	           --uts=host \
	           --pid=host \
	           --rm -ti \
	           -v $(SOURCE_DIR):/code \
                   -v /var/run/docker.sock:/var/run/docker.sock \
	           --name=testenv \
	           calico/test \
	           sh

dist/calicoctl:
	-docker rm -f calicoctl
	docker pull $(CTL_CONTAINER_NAME)
	docker create --name calicoctl $(CTL_CONTAINER_NAME)
	docker cp calicoctl:calicoctl dist/calicoctl && \
	  test -e dist/calicoctl && \
	  touch dist/calicoctl
	-docker rm -f calicoctl

dist/calicoctlv2:
	-docker rm -f calicoctlv2
	docker pull $(CTL_CONTAINER_V2_NAME)
	docker create --name calicoctlv2 $(CTL_CONTAINER_V2_NAME)
	docker cp calicoctlv2:calicoctl dist/calicoctlv2 && \
	  test -e dist/calicoctlv2 && \
	  touch dist/calicoctlv2
	-docker rm -f calicoctlv2

## Run etcd as a container (calico-etcd)
run-etcd: stop-etcd
	docker run --detach \
	--net=host \
	--entrypoint=/usr/local/bin/etcd \
	--name calico-etcd quay.io/coreos/etcd:$(ETCD_VER) \
	--advertise-client-urls "http://$(LOCAL_IP_ENV):2379,http://127.0.0.1:2379,http://$(LOCAL_IP_ENV):4001,http://127.0.0.1:4001" \
	--listen-client-urls "http://0.0.0.0:2379,http://0.0.0.0:4001"


.PHONY: stop-etcd
stop-etcd:
	@-docker rm -f calico-etcd

# This depends on clean to ensure that dependent images get untagged and repulled
.PHONY: semaphore
semaphore: clean
	# Clean up unwanted files to free disk space.
	bash -c 'rm -rf /home/runner/{.npm,.phpbrew,.phpunit,.kerl,.kiex,.lein,.nvm,.npm,.phpbrew,.rbenv} /usr/local/golang /var/lib/mongodb'

	# Run the containerized tests first.
	# Need ut's and st's added when we have them.
	#$(MAKE) test-containerized
	#$(MAKE) st

	$(MAKE) calico/upgrade

	# Make sure that calico-upgrade builds cross-platform.
	$(MAKE) dist/calico-upgrade-darwin-amd64 dist/calico-upgrade-windows-amd64.exe

	# Run the tests.
	# Only running make st since test-containerized has no ut to execute.
	$(MAKE) st

release: clean
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
	git tag $(VERSION)

	# Check to make sure the tag isn't "-dirty".
	if git describe --tags --dirty | grep dirty; \
	then echo current git working tree is "dirty". Make sure you do not have any uncommitted changes ;false; fi

	# Build the calico-upgrade binaries.
	$(MAKE) dist/calico-upgrade dist/calico-upgrade-darwin-amd64 dist/calico-upgrade-windows-amd64.exe
	$(MAKE) calico/upgrade

	# Check that the version output includes the version specified.
	# Tests that the "git tag" makes it into the binaries. Main point is to catch "-dirty" builds
	# Release is currently supported on darwin / linux only.
	if ! docker run $(CALICO_UPGRADE_CONTAINER_NAME) version | grep 'Version:\s*$(VERSION)$$'; then \
	  echo "Reported version:" `docker run $(CALICO_UPGRADE_CONTAINER_NAME) version` "\nExpected version: $(VERSION)"; \
	  false; \
	else \
	  echo "Version check passed\n"; \
	fi

	# Retag images with corect version and quay
	docker tag $(CALICO_UPGRADE_CONTAINER_NAME) $(CALICO_UPGRADE_CONTAINER_NAME):$(VERSION)
	docker tag $(CALICO_UPGRADE_CONTAINER_NAME) quay.io/$(CALICO_UPGRADE_CONTAINER_NAME):$(VERSION)
	docker tag $(CALICO_UPGRADE_CONTAINER_NAME) quay.io/$(CALICO_UPGRADE_CONTAINER_NAME):latest

	# Check that images were created recently and that the IDs of the versioned and latest images match
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(CALICO_UPGRADE_CONTAINER_NAME)
	@docker images --format "{{.CreatedAt}}\tID:{{.ID}}\t{{.Repository}}:{{.Tag}}" $(CALICO_UPGRADE_CONTAINER_NAME):$(VERSION)

	@echo ""
	@echo "# Push the created tag to GitHub"
	@echo "  git push origin $(VERSION)"
	@echo ""
	@echo "# Now, create a GitHub release from the tag, add release notes, and attach the following binaries:"
	@echo "- dist/calico-upgrade"
	@echo "- dist/calico-upgrade-darwin-amd64"
	@echo "- dist/calico-upgrade-windows-amd64.exe"
	@echo "# To find commit messages for the release notes:  git log --oneline <old_release_version>...$(VERSION)"
	@echo ""
	@echo "# Now push the newly created release images."
	@echo "  docker push calico/upgrade:$(VERSION)"
	@echo "  docker push quay.io/calico/upgrade:$(VERSION)"
	@echo ""
	@echo "# For the final release only, push the latest tag"
	@echo "# DO NOT PUSH THESE IMAGES FOR RELEASE CANDIDATES OR ALPHA RELEASES" 
	@echo "  docker push calico/upgrade:latest"
	@echo "  docker push quay.io/calico/upgrade:latest"
	@echo ""
	@echo "See RELEASING.md for detailed instructions."

## Clean enough that a new release build will be clean
clean: clean-calico-upgrade
	find . -name '*.created' -exec rm -f {} +
	rm -rf dist build certs *.tar vendor

.PHONY: help
## Display this help text
help: # Some kind of magic from https://gist.github.com/rcmachado/af3db315e31383502660
	$(info Available targets)
	@awk '/^[a-zA-Z\-\_0-9\/]+:/ {                                      \
		nb = sub( /^## /, "", helpMsg );                                \
		if(nb == 0) {                                                   \
			helpMsg = $$0;                                              \
			nb = sub( /^[^:]*:.* ## /, "", helpMsg );                   \
		}                                                               \
		if (nb)                                                         \
			printf "\033[1;31m%-" width "s\033[0m %s\n", $$1, helpMsg;  \
	}                                                                   \
	{ helpMsg = $$0 }'                                                  \
	width=20                                                            \
	$(MAKEFILE_LIST)
