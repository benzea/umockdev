
namespace UMockdev {

using Ioctl;
using pcap;

const int URB_TRANSFER_IN = 0x80;
const int URB_ISOCHRONOUS = 0x0;
const int URB_INTERRUPT = 0x1;
const int URB_CONTROL = 0x2;
const int URB_BULK = 0x3;

private struct UrbInfo {
    IoctlData urb_data;
    IoctlData buffer_data;
    uint64 pcap_id;
}


internal class IoctlUsbPcapHandler : IoctlBase {

    /* Make up some capabilities (that have useful properties) */
    const uint32 capabilities = USBDEVFS_CAP_BULK_SCATTER_GATHER |
                                USBDEVFS_CAP_BULK_CONTINUATION |
                                USBDEVFS_CAP_NO_PACKET_SIZE_LIM |
                                USBDEVFS_CAP_REAP_AFTER_DISCONNECT |
                                USBDEVFS_CAP_ZERO_PACKET;
    private pcap.pcap rec;
    private Array<UrbInfo?> urbs;
    private int bus;
    private int device;

    public IoctlUsbPcapHandler(MainContext? ctx, string file, int bus, int device)
    {
        char errbuf[pcap.ERRBUF_SIZE];
        base (ctx);

        this.bus = bus;
        this.device = device;

        rec = new pcap.pcap.open_offline(file, errbuf);

        if (rec.datalink() != dlt.USB_LINUX_MMAPPED)
            error("Only DLT_USB_LINUX_MMAPPED recordings are supported!");

        urbs = new Array<UrbInfo?>();
    }

    public override bool handle_ioctl(IoctlClient client) {
        IoctlData? data = null;
        ulong request = client.request;
        ulong size = (request >> Ioctl._IOC_SIZESHIFT) & ((1 << Ioctl._IOC_SIZEBITS) - 1);

        try {
            data = client.arg.resolve(0, size, true, true);
        } catch (IOError e) {
            warning("Error resolving IOCtl data: %s", e.message);
            return false;
        }

        switch (request) {
            case USBDEVFS_GET_CAPABILITIES:
                *(uint32*) data.data = capabilities;
                data.dirty(false);

                client.complete(0, 0);
                return true;

            case USBDEVFS_CLAIMINTERFACE:
            case USBDEVFS_RELEASEINTERFACE:
            case USBDEVFS_CLEAR_HALT:
            case USBDEVFS_RESET:
            case USBDEVFS_RESETEP:
                client.complete(0, 0);
                return true;

            case USBDEVFS_DISCARDURB:
                for (int i = 0; i < urbs.length; i++) {
                    if (urbs.index(i).urb_data.client_addr == *((ulong*)client.arg.data)) {
                        /* Found the urb, remove it and return success */
                        urbs.remove_index(i);
                        client.complete(0, 0);
                        return true;
                    }
                }

                client.complete(-1, Posix.EINVAL);
                return true;


            case USBDEVFS_SUBMITURB:
                /* Just put the urb information into our queue (but resolve the buffer). */
                Ioctl.usbdevfs_urb *urb = (Ioctl.usbdevfs_urb*) data.data;
                size_t offset = (ulong) &urb.buffer - (ulong) urb;
                UrbInfo info = { };

                info.urb_data = data;
                try {
                    info.buffer_data = data.resolve(offset, urb.buffer_length, true, false);;
                } catch (IOError e) {
                    warning("Error resolving IOCtl data: %s", e.message);
                    return false;
                }
                info.pcap_id = 0;

                urbs.append_val(info);
                client.complete(0, 0);
                return true;

            case USBDEVFS_REAPURB:
            case USBDEVFS_REAPURBNDELAY:
                UrbInfo? urb_info = next_reapable_urb();

                if (urb_info != null) {
                    try {
                        data.set_ptr(0, urb_info.urb_data);
                        client.complete(0, 0);
                        return true;
                    } catch (IOError e) {
                        return false;
                    }
                } else {
                    client.complete(-1, Posix.ENOENT);
                    return true;
                }

            default:
                client.complete(-1, Posix.ENOTTY);
                return true;
        }
    }

    /* If we are stuck, we need to be able to look at the already fetched
     * packet. As such, keep it in a global state.
     */
    private pcap.pkthdr cur_hdr;
    private unowned uint8[]? cur_buf = null;

    private UrbInfo? next_reapable_urb() {
        /* Fetch the first packet if we do not have one. */
        if (cur_buf == null)
            cur_buf = rec.next(ref cur_hdr);

        for (; cur_buf != null; cur_buf = rec.next(ref cur_hdr)) {
            assert(cur_hdr.caplen >= 64);

            usb_header_mmapped *urb_hdr = (void*) cur_buf;

            /* Discard anything from a different bus/device */
            if (urb_hdr.bus_id != bus || urb_hdr.device_address != device)
                continue;

            /* Submit */
            if (urb_hdr.event_type == 'S') {
                /* Check each pending URB (in oldest to newest order) and see
                 * if the information matches, and if yes, we mark the urb as
                 * submitted (and therefore reapable).
                 */
                int i;
                for (i = 0; i < urbs.length; i++) {
                    unowned UrbInfo? urb_data = urbs.index(i);
                    Ioctl.usbdevfs_urb *urb = (Ioctl.usbdevfs_urb*) urb_data.urb_data.data;

                    /* Urb already submitted. */
                    if (urb_data.pcap_id != 0)
                        continue;

                    if ((urb.type != urb_hdr.transfer_type) ||
                        (urb.endpoint != urb_hdr.endpoint_number) ||
                        (urb.buffer_length != urb_hdr.urb_len))
                        continue;

                    if (urb_hdr.data_len > 0) {
                        /* This means the endpoint must be "& 0x1" true */
                        assert((urb.endpoint & 0x01) == 0x01);
                        assert(urb_hdr.data_len == urb.buffer_length);

                        /* Compare the full buffer (as we are outgoing) */
                        if (Posix.memcmp(urb.buffer, &cur_buf[sizeof(usb_header_mmapped)], urb.buffer_length) != 0) {
                            continue;
                        }
                    }

                    /* Everything matches, mark as submitted */
                    urb_data.pcap_id = urb_hdr.id;

                    /* Packet was handled. */
                    break;
                }

                /* Found a packet, continue! */
                if (i != urbs.length)
                    continue;
            } else {
                UrbInfo? urb_info = null;
                Ioctl.usbdevfs_urb *urb = null;
                /* 'C' or 'E'; we don't implement errors yet */

                assert(urb_hdr.event_type == 'C');

                for (int i = 0; i < urbs.length; i++) {
                    urb_info = urbs.index(i);

                    if (urb_info.pcap_id == urb_hdr.id) {
                        urb = (Ioctl.usbdevfs_urb*) urb_info.urb_data.data;
                        urbs.remove_index(i);
                        break;
                    }

                    urb_info = null;
                }

                /* We don't have a submit node for this urb.
                 * Just ignore it as it is probably a control transfer that was
                 * initiated by the kernel. */
                if (urb == null)
                    continue;

                /* We can reap this urb!
                 * Copy data back if we have it. */
                if (urb_hdr.data_len > 0) {
                    Posix.memcpy(urb.buffer, &cur_buf[sizeof(usb_header_mmapped)], urb_hdr.data_len);
                    urb_info.buffer_data.dirty(false);
                }
                urb.status = (int) urb_hdr.status;
                urb.actual_length = (int) urb_hdr.urb_len;
                urb_info.urb_data.dirty(false);

                /* Does this need further handling? */
                assert(urb_hdr.start_frame == 0);
                urb.start_frame = (int) urb_hdr.start_frame;

                return urb_info;
            }

            /* Packet not handled.
             * If it was a control transfer, still just ignore it as it is
             * probably one generated by the kernel rather than the application.
             */
            if (urb_hdr.transfer_type == URB_CONTROL)
                continue;

            /* The current packet cannot be reaped at this point, give up. */
            return null;
        }

        return null;
    }
}

}
