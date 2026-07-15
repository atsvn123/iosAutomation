import json
import os
import sys

from zxtouch.client import zxtouch


DEVICE_IP = os.environ.get("ZXTOUCH_DEVICE_IP", "192.168.1.100")


def main():
    print("Connecting to ZXTouch device at {}:6000...".format(DEVICE_IP))

    try:
        device = zxtouch(DEVICE_IP)
    except OSError as exc:
        print("Unable to connect to device: {}".format(exc))
        return 1

    try:
        success, result = device.get_device_details()
        if not success:
            print("ZXTouch returned an error: {}".format(result))
            return 1

        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    finally:
        device.disconnect()


if __name__ == "__main__":
    sys.exit(main())
