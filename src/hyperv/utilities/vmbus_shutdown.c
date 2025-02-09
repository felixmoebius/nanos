/*-
 * Copyright (c) 2014,2016 Microsoft Corp.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice unmodified, this list of conditions, and the following
 *    disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
 * IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
 * OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <kernel.h>
#include <hyperv_internal.h>
#include "vmbus_icvar.h"
#include "vmbus_icreg.h"
#include "vmbus.h"
#include "io.h"
#include "hyperv_platform.h"

#define VMBUS_SHUTDOWN_FWVER_MAJOR  3
#define VMBUS_SHUTDOWN_FWVER     \
   VMBUS_IC_VERSION(VMBUS_SHUTDOWN_FWVER_MAJOR, 0)

#define VMBUS_SHUTDOWN_MSGVER_MAJOR 3
#define VMBUS_SHUTDOWN_MSGVER    \
   VMBUS_IC_VERSION(VMBUS_SHUTDOWN_MSGVER_MAJOR, 0)

static const struct hyperv_guid vmbus_shutdown_device_type = {
   .hv_guid = { 0x31, 0x60, 0x0b, 0x0e, 0x13, 0x52, 0x34, 0x49,
       0x81, 0x8b, 0x38, 0xd9, 0x0c, 0xed, 0x39, 0xdb }
};

closure_function(0, 1, void, hv_sync_complete,
                 int, status) {
    HV_SHUTDOWN();
}

void unix_shutdown(void);

static void vmbus_shutdown_cb(struct vmbus_channel *chan, void *xsc)
{
   struct vmbus_ic_softc *sc = xsc;
   struct vmbus_icmsg_hdr *hdr;
   struct vmbus_icmsg_shutdown *msg;
   int dlen, error, do_shutdown = 0;
   uint64_t xactid;
   void *data;

   /*
    * Receive request.
    */
   data = sc->ic_buf;
   dlen = sc->ic_buflen;
   error = vmbus_chan_recv(chan, data, &dlen, &xactid);
   assert(error != ENOBUFS); // icbuf is not large enough
   if (error)
      return;

   if (dlen < sizeof(*hdr)) {
      vmbus_util_debug("invalid data len %d", dlen);
      return;
   }
   hdr = data;

   /*
    * Update request, which will be echoed back as response.
    */
   switch (hdr->ic_type) {
   case VMBUS_ICMSG_TYPE_NEGOTIATE:
      error = vmbus_ic_negomsg(sc, data, &dlen,
          VMBUS_SHUTDOWN_FWVER, VMBUS_SHUTDOWN_MSGVER);
      if (error)
         return;
      break;

   case VMBUS_ICMSG_TYPE_SHUTDOWN:
      if (dlen < VMBUS_ICMSG_SHUTDOWN_SIZE_MIN) {
         vmbus_util_debug("invalid shutdown len %d", dlen);
         return;
      }
      msg = data;

      /* XXX ic_flags definition? */
      if (msg->ic_haltflags == 0 || msg->ic_haltflags == 1) {
         vmbus_util_debug("shutdown requested");
         hdr->ic_status = VMBUS_ICMSG_STATUS_OK;
         do_shutdown = 1;
      } else {
         vmbus_util_debug("unknown shutdown flags 0x%08x", msg->ic_haltflags);
         hdr->ic_status = VMBUS_ICMSG_STATUS_FAIL;
      }
      break;

   default:
      vmbus_util_debug("got 0x%08x icmsg", hdr->ic_type);
      break;
   }

   /*
    * Send response by echoing the request back.
    */
   vmbus_ic_sendresp(sc, chan, data, dlen, xactid);

   if (do_shutdown)
       unix_shutdown();
}


static status vmbus_shutdown_attach(kernel_heaps kh, hv_device* device)
{
    heap h = heap_general(kh);

    struct vmbus_ic_softc *sc = allocate_zero(h, sizeof(struct vmbus_ic_softc));
    assert(sc != INVALID_ADDRESS);

    sc->general = h;
    sc->hs_dev = device;

    vmbus_ic_attach(sc, vmbus_shutdown_cb);
    vm_halt = closure(sc->general, hv_sync_complete);

    return STATUS_OK;
}


closure_function(1, 3, boolean, vmbus_shutdown_probe,
                 kernel_heaps, kh,
                 struct hv_device*, device,
                 storage_attach, unused,
                 boolean*, unused1)
{
    status s = vmbus_shutdown_attach(bound(kh), device);
    if (!is_ok(s)) {
        msg_err("attach failed with status %v\n", s);
        return false;
    }
    return true;
}


void init_vmbus_shutdown(kernel_heaps kh)
{
    register_vmbus_driver(&vmbus_shutdown_device_type, closure(heap_general(kh), vmbus_shutdown_probe, kh));
}
