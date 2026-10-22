import os
import sys
import unittest


PYTHON_CLIENT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python")
)
sys.path.insert(0, PYTHON_CLIENT_ROOT)

from zxtouch import tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class ScriptedSocket:
    def __init__(self, replies):
        self.replies = [bytes(reply) for reply in replies]
        self.sent = []

    def sendall(self, data):
        self.sent.append(bytes(data))

    def recv(self, size):
        if not self.replies:
            return b""
        reply = self.replies[0]
        result = reply[:size]
        if len(result) == len(reply):
            self.replies.pop(0)
        else:
            self.replies[0] = reply[size:]
        return result


def make_device(replies):
    device = zxtouch.__new__(zxtouch)
    device.s = ScriptedSocket(replies)
    device._recv_buffer = bytearray()
    return device


LIT = (b"0;;blanked=0;;method=-;;remaining=0;;brightness=0.420;;saved=-;;hidden=-;;"
       b"locked=0;;reason=lease expired\r\n")
BLANK = (b"0;;blanked=1;;method=overlay;;remaining=600;;brightness=0.000;;saved=0.420;;hidden=1;;"
         b"locked=0;;reason=-\r\n")


class DisplayProtocolTests(unittest.TestCase):
    def test_task_number(self):
        self.assertEqual(tasktypes.TASK_DISPLAY, 31)

    def test_status_parses_every_field(self):
        device = make_device([LIT])

        status = device.display_status()

        self.assertEqual(device.s.sent, [b"31status\r\n"])
        self.assertEqual(status, {"blanked": False, "method": None, "remaining": 0.0, "brightness": 0.42,
                                  "saved": None, "hidden": None, "locked": 0, "reason": "lease expired"})

    def test_blank_sends_method_lease_and_options(self):
        device = make_device([BLANK])

        status = device.blank(600, brightness=0, mask=0x12)

        self.assertEqual(device.s.sent, [b"31blank;;overlay;;600;;brightness=0;;mask=0x12\r\n"])
        self.assertTrue(status["blanked"])
        self.assertEqual(status["method"], "overlay")
        self.assertEqual(status["saved"], 0.42)
        self.assertEqual(status["hidden"], 1)
        self.assertIsNone(status["reason"])

    def test_blank_without_options(self):
        device = make_device([BLANK])

        device.blank(30, method="bks")

        self.assertEqual(device.s.sent, [b"31blank;;bks;;30\r\n"])

    def test_renew_unblank_and_brightness(self):
        device = make_device([BLANK, LIT, b"0;;previous=0.420;;brightness=0.100\r\n"])

        device.renew(90)
        lit = device.unblank()
        level = device.set_brightness(0.1)

        self.assertEqual(device.s.sent, [b"31renew;;90\r\n", b"31unblank\r\n", b"31brightness;;0.1\r\n"])
        self.assertFalse(lit["blanked"])
        self.assertEqual(level, {"previous": 0.42, "brightness": 0.1})

    def test_error_reply_raises_with_message(self):
        device = make_device([b"-1;;device is locked\r\n"])

        with self.assertRaisesRegex(RuntimeError, "blank failed: device is locked"):
            device.blank(60)

    def test_reply_split_across_reads(self):
        device = make_device([LIT[:20], LIT[20:-1], LIT[-1:]])

        self.assertFalse(device.display_status()["blanked"])

    def test_bad_arguments_never_reach_the_socket(self):
        device = make_device([])
        for call in (lambda: device.blank(0), lambda: device.blank(3601), lambda: device.blank(True),
                     lambda: device.blank(60, method="lock"), lambda: device.blank(60, brightness=1.5),
                     lambda: device.blank(60, mask=0x10000), lambda: device.renew(-5),
                     lambda: device.set_brightness(-0.1)):
            with self.assertRaises(ValueError):
                call()
        self.assertEqual(device.s.sent, [])

    def test_malformed_field_raises(self):
        device = make_device([b"0;;blanked\r\n"])

        with self.assertRaisesRegex(RuntimeError, "Malformed"):
            device.display_status()


if __name__ == "__main__":
    unittest.main()
