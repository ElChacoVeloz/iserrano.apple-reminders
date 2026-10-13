#!/usr/bin/env python3
"""Helper tests: the list color iCloud sends, reduced to #rrggbb so the bar can
paint it, and the sample data behind `fetch --demo`. Pure stdlib."""

import json
import os
import sys
import unittest
from datetime import date

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


class DemoPayloadTests(unittest.TestCase):
    """The canned answer behind `fetch --demo`: the same shape as a real fetch, so
    the widget can be previewed, themed and screenshotted without touching iCloud."""

    ITEM_KEYS = {"id", "content", "notes", "listId", "list", "color", "allDay",
                 "due", "time", "overdue", "flagged", "priority", "section"}

    def setUp(self):
        self.payload = helper.demo_payload()

    def test_it_answers_ok_and_flags_itself_as_a_demo(self):
        self.assertTrue(self.payload["ok"])
        self.assertIs(self.payload["demo"], True)

    def test_every_item_carries_the_keys_the_widget_reads(self):
        for item in self.payload["items"]:
            self.assertEqual(set(item), self.ITEM_KEYS)

    def test_the_total_matches_the_items(self):
        self.assertEqual(self.payload["total"], len(self.payload["items"]))

    def test_there_is_something_overdue_and_it_goes_first(self):
        first = self.payload["items"][0]
        self.assertTrue(first["overdue"])
        self.assertEqual(first["section"], "Vencidos")
        self.assertFalse(any(item["overdue"] for item in self.payload["items"][1:]))
        self.assertTrue(all(item["section"] == "Hoy" for item in self.payload["items"][1:]))

    def test_nothing_is_due_in_the_future(self):
        today = date.today().isoformat()
        for item in self.payload["items"]:
            self.assertLessEqual(item["due"], today)

    def test_the_lists_are_the_demo_ones_and_carry_a_color(self):
        ids = [lst["id"] for lst in self.payload["lists"]]
        self.assertTrue(ids)
        self.assertTrue(all(item.startswith("demo-") for item in ids))
        colors = {item["color"] for item in self.payload["items"]}
        self.assertTrue(all(color.startswith("#") and len(color) == 7 for color in colors))

    def test_times_are_either_empty_or_hh_mm(self):
        for item in self.payload["items"]:
            self.assertRegex(item["time"], r"^(\d{2}:\d{2})?$")
            self.assertEqual(item["allDay"], item["time"] == "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
