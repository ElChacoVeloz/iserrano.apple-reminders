#!/usr/bin/env python3
"""Helper tests: the list color iCloud sends, reduced to #rrggbb so the bar can
paint it. Pure stdlib."""

import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

import apple_reminders as helper  # noqa: E402

# Exactly what iCloud sends: JSON as text, with the hex and the channels.
YELLOW = ('{"daSymbolicColorName":"yellow","red":1,"green":0.80000000000000004,'
          '"ckSymbolicColorName":"yellow","daHexString":"#FFCC00","colorRGBSpace":2,'
          '"blue":0,"alpha":1}')


class ColorHexTests(unittest.TestCase):
    def test_the_dictionary_icloud_sends_as_text(self):
        self.assertEqual(helper.color_hex(YELLOW), "#ffcc00")

    def test_the_same_dictionary_already_parsed(self):
        self.assertEqual(helper.color_hex(json.loads(YELLOW)), "#ffcc00")

    def test_a_plain_hex_passes_through(self):
        self.assertEqual(helper.color_hex("#3E63DD"), "#3e63dd")

    def test_channels_are_used_when_there_is_no_hex(self):
        self.assertEqual(helper.color_hex({"red": 0.2, "green": 0.4, "blue": 1}), "#3366ff")

    def test_nothing_usable_gives_nothing(self):
        for value in ("", None, 7, "not a color", "{}", {"daHexString": "blue"}, "[1,2]"):
            self.assertEqual(helper.color_hex(value), "", value)


if __name__ == "__main__":
    unittest.main(verbosity=2)
