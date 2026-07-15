import os
import sys

from zxtouch.client import zxtouch
from zxtouch.toasttypes import TOAST_SUCCESS, TOAST_TOP


DEVICE_IP = os.environ.get("ZXTOUCH_DEVICE_IP", "192.168.1.39")


def main():
    print("Connecting to ZXTouch device at {}:6000...".format(DEVICE_IP))

    try:
        device = zxtouch(DEVICE_IP)
    except OSError as exc:
        print("Unable to connect to device: {}".format(exc))
        print("Check that the iPhone is on the same network and ZXTouch is running.")
        return 1

    try:

        ok, info = device.crane_get_containers("com.vib.myvib2prod")
        print(ok, info)

        ok, launched = device.crane_launch_app_with_container("com.vib.myvib2prod", '19ED63C1-5698-46A4-B0AA-B37C2CAA660A')
        print(ok, info)

    finally:
        device.disconnect()


if __name__ == "__main__":
    sys.exit(main())
