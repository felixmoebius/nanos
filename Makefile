SUBDIR=		$(PLATFORMDIR) klib test tools

# runtime tests / ready-to-use targets
TARGET=		webg

CLEANFILES+=	$(IMAGE)
CLEANDIRS+=	$(OUTDIR)/image $(OUTDIR)/platform/$(PLATFORM) $(OUTDIR)/platform

ACPICA_DIR=	$(VENDORDIR)/acpica
LWIPDIR=	$(VENDORDIR)/lwip
MBEDTLS_DIR=	$(VENDORDIR)/mbedtls

# VMware
QEMU_IMG=	qemu-img

# GCE
GCLOUD= 	gcloud
GSUTIL=		gsutil
GCE_PROJECT=	prod-1033
GCE_BUCKET=	nanos-test/gce-images
GCE_IMAGE=	nanos-$(TARGET)
GCE_INSTANCE=	nanos-$(TARGET)

# AWS
AWS=		aws
JQ=		jq
PRINTF=		printf
CLEAR_LINE=	[1K\r
AWS_S3_BUCKET=	nanos-test
AWS_AMI_IMAGE=	nanos-$(TARGET)

MKFS=		$(TOOLDIR)/mkfs
DUMP=		$(TOOLDIR)/dump
BOOTIMG=	$(PLATFORMOBJDIR)/boot/boot.img
UEFI_LOADER=$(PLATFORMOBJDIR)/boot/$(UEFI_FILE)
KERNEL=		$(PLATFORMOBJDIR)/bin/kernel.img

all: image

.PHONY: distclean image release target tools

include rules.mk

ifeq ($(ARCH),x86_64)
UEFI_FILE=	bootx64.efi
else
ifeq ($(ARCH),aarch64)
UEFI_FILE=	bootaa64.efi
endif
endif

THIRD_PARTY= $(ACPICA_DIR)/.vendored $(LWIPDIR)/.vendored $(MBEDTLS_DIR)/.vendored

$(ACPICA_DIR)/.vendored: GITFLAGS= --depth 1  https://github.com/acpica/acpica.git -b R09_30_21
$(LWIPDIR)/.vendored: GITFLAGS= --depth 1  https://github.com/nanovms/lwip.git -b STABLE-2_1_x
$(MBEDTLS_DIR)/.vendored: GITFLAGS= --depth 1 https://github.com/nanovms/mbedtls.git

image: $(THIRD_PARTY) tools
	$(Q) $(MAKE) -C klib
	$(Q) $(MAKE) -C $(PLATFORMDIR) image TARGET=$(TARGET)

release: $(THIRD_PARTY) tools
	$(Q) $(MAKE) -C $(PLATFORMDIR) boot
	$(Q) $(MAKE) -C klib
	$(Q) $(MAKE) -C $(PLATFORMDIR) kernel
	$(Q) $(RM) -r release
	$(Q) $(MKDIR) release
	$(CP) $(MKFS) release
	$(CP) $(DUMP) release
	if [ -f $(BOOTIMG) ]; then $(CP) $(BOOTIMG) release; fi
	if [ -f $(UEFI_LOADER) ]; then $(CP) $(UEFI_LOADER) release; fi
	$(CP) $(KERNEL) release
	$(Q) $(MKDIR) release/klibs
	$(CP) $(OUTDIR)/klib/bin/* release/klibs
	cd release && $(TAR) -czvf nanos-release-$(REL_OS)-${version}.tar.gz *

target: contgen
	$(Q) $(MAKE) -C test/runtime $(TARGET)

tools: contgen
	$(Q) $(MAKE) -C $@

distclean: clean
	$(Q) $(RM) -rf $(VENDORDIR)

##############################################################################
# tests

.PHONY: test-all test test-noaccel

contgen mkfs tfs-fuse:
	$(Q) $(MAKE) -C tools $@

test-all: contgen
	$(Q) $(MAKE) -C test

test test-noaccel: image
	$(Q) $(MAKE) -C test test
	$(Q) $(MAKE) runtime-tests$(subst test,,$@)

RUNTIME_TESTS=	aio creat dup epoll eventfd fadvise fallocate fcntl fst fs_full futex futexrobust getdents getrandom hw hwg hws inotify io_uring klibs mkdir mmap netlink netsock pipe readv rename sendfile signal sigoverflow socketpair syslog time unlink thread_test tlbshootdown tun unixsocket vsyscall write writev

.PHONY: runtime-tests runtime-tests-noaccel

runtime-tests runtime-tests-noaccel: image
	$(foreach t,$(RUNTIME_TESTS),$(call execute_command,$(Q) $(MAKE) run$(subst runtime-tests,,$@) TARGET=$t))

run: contgen image
	$(Q) $(MAKE) -C $(PLATFORMDIR) TARGET=$(TARGET) run

run-bridge: contgen image
	$(Q) $(MAKE) -C $(PLATFORMDIR) TARGET=$(TARGET) run-bridge

run-noaccel: contgen image
	$(Q) $(MAKE) -C $(PLATFORMDIR) TARGET=$(TARGET) run-noaccel

kernel.dis: contgen image
	$(Q) $(MAKE) -C $(PLATFORMDIR) kernel.dis

##############################################################################
# VMware

CLEANFILES+=	$(IMAGE:.raw=.vmdk)

vmdk-image: image
	$(Q) $(QEMU_IMG) convert -f raw -O vmdk -o subformat=monolithicFlat $(IMAGE) $(IMAGE:.raw=.vmdk)

##############################################################################
# Hyper-V

CLEANFILES+=	$(IMAGE:.raw=.vhdx)

vhdx-image: image
	$(Q) $(QEMU_IMG) convert -f raw -O vhdx -o subformat=dynamic $(IMAGE) $(IMAGE:.raw=.vhdx)

##############################################################################
# Azure (Hyper-V)

CLEANFILES+=	$(IMAGE:.raw=.vhd)

MIN_AZURE_IMG_SIZE=20971520

vhd-image: image
	$(Q) size=$$($(QEMU_IMG) info -f raw --output json $(IMAGE) | $(JQ) -r 'def roundup(x; y): (x + y - 1) / y | floor | . * y; fmax(.["virtual-size"]; $(MIN_AZURE_IMG_SIZE)) | roundup(.; 1048576)'); $(QEMU_IMG) resize -f raw $(IMAGE) $$size
	$(Q) $(QEMU_IMG) convert -f raw -O vpc -o subformat=fixed,force_size $(IMAGE) $(IMAGE:.raw=.vhd)

##############################################################################
# GCE

.PHONY: upload-gce-image gce-image delete-gce-image
.PHONY: run-gce delete-gce gce-console

CLEANFILES+=	$(OUTDIR)/image/*-image.tar.gz

upload-gce-image: image
	$(Q) cd $(dir $(IMAGE)) && $(GNUTAR) cfz $(GCE_IMAGE)-image.tar.gz $(notdir $(IMAGE))
	$(Q) $(GSUTIL) cp $(dir $(IMAGE))$(GCE_IMAGE)-image.tar.gz gs://$(GCE_BUCKET)/$(GCE_IMAGE)-image.tar.gz

gce-image: upload-gce-image delete-gce-image
	$(Q) $(GCLOUD) compute --project=$(GCE_PROJECT) images create $(GCE_IMAGE) --source-uri=https://storage.googleapis.com/$(GCE_BUCKET)/$(GCE_IMAGE)-image.tar.gz

delete-gce-image:
	- $(Q) $(GCLOUD) compute --project=$(GCE_PROJECT) images delete $(GCE_IMAGE) --quiet

run-gce: delete-gce
	$(Q) $(GCLOUD) compute --project=$(GCE_PROJECT) instances create $(GCE_INSTANCE) --machine-type=custom-1-2048 --image=$(GCE_IMAGE) --image-project=$(GCE_PROJECT) --tags=nanos
	$(Q) $(MAKE) gce-console

delete-gce:
	- $(Q) $(GCLOUD) compute --project=$(GCE_PROJECT) instances delete $(GCE_INSTANCE) --quiet

gce-console:
	$(Q) $(GCLOUD) compute --project=$(GCE_PROJECT) instances tail-serial-port-output $(GCE_INSTANCE)

##############################################################################
# AWS
.PHONY: upload-ec2-image create-ec2-snapshot

upload-ec2-image:
	$(Q) $(AWS) s3 cp $(IMAGE) s3://$(AWS_S3_BUCKET)/$(AWS_AMI_IMAGE).raw

create-ec2-snapshot: upload-ec2-image
	$(Q) json=`$(AWS) ec2 import-snapshot --disk-container "Description=NanoVMs Test,Format=raw,UserBucket={S3Bucket=$(AWS_S3_BUCKET),S3Key=$(AWS_AMI_IMAGE).raw}"` && \
		import_task_id=`$(ECHO) "$$json" | $(JQ) -r .ImportTaskId` && \
		while :; do \
			json=`$(AWS) ec2 describe-import-snapshot-tasks --import-task-ids $$import_task_id`; \
			status=`$(ECHO) "$$json" | $(JQ) -r ".ImportSnapshotTasks[0].SnapshotTaskDetail.Status"`; \
			if [ x"$$status" = x"completed" ]; then \
			        $(PRINTF) "$(CLEAR_LINE)Task $$import_task_id: $$status\n"; \
				break; \
			fi; \
			progress=`$(ECHO) "$$json" | $(JQ) -r ".ImportSnapshotTasks[0].SnapshotTaskDetail.Progress?"`; \
			status_message=`$(ECHO) "$$json" | $(JQ) -r ".ImportSnapshotTasks[0].SnapshotTaskDetail.StatusMessage?"`; \
			$(PRINTF) "$(CLEAR_LINE)Task $$import_task_id: $$status_message ($$progress%%)"; \
		done

ifeq ($(UNAME_s),Darwin)
REL_OS=         darwin
else
REL_OS=         linux
endif
