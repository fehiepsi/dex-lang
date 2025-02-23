# Copyright 2020 Google LLC
#
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file or at
# https://developers.google.com/open-source/licenses/bsd

import unittest
from textwrap import dedent

import dex

class APITest(unittest.TestCase):
  def test_eval(self):
    cases = [
      "2.5",
      "4",
      "[2, 3, 4]",
    ]
    for expr in cases:
      assert str(dex.eval(expr)) == expr

  def test_module_attrs(self):
    m = dex.Module(dedent("""
    x = 2.5
    y = [2, 3, 4]
    """))
    assert str(m.x) == "2.5"
    assert str(m.y) == "[2, 3, 4]"

  def test_function_call(self):
    m = dex.Module(dedent("""
    def addOne (x: Float) : Float = x + 1.0
    """))
    x = dex.eval("2.5")
    y = dex.eval("[2, 3, 4]")
    assert str(m.addOne(x)) == "3.5"
    assert str(m.sum(y)) == "9"

  def test_scalar_conversions(self):
    assert float(dex.eval("5.0")) == 5.0
    assert int(dex.eval("5")) == 5
    assert str(dex.Atom(5)) == "5"
    assert str(dex.Atom(5.0)) == "5."


if __name__ == "__main__":
  unittest.main()
