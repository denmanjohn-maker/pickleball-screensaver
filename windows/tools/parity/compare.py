"""Verify golden traces against a fresh unchanged Swift export, allowing libm rounding only."""
import json
import math
import sys


def compare(expected, actual, path="trace"):
    if isinstance(expected, float):
        if not isinstance(actual, (int, float)) or not math.isfinite(actual) or abs(expected - actual) > 1e-7:
            raise AssertionError(f"{path}: vector drift")
    elif isinstance(expected, dict):
        assert expected.keys() == actual.keys(), f"{path}: fields changed"
        for key, value in expected.items():
            compare(value, actual[key], f"{path}.{key}")
    elif isinstance(expected, list):
        assert len(expected) == len(actual), f"{path}: count changed"
        for index, (a, b) in enumerate(zip(expected, actual)):
            compare(a, b, f"{path}[{index}]")
    else:
        assert expected == actual, f"{path}: discrete trace changed"


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as a, open(sys.argv[2], encoding="utf-8") as b:
        compare(json.load(a), json.load(b))
    print("PASS: exact discrete events/frames/scores and vectors within 1e-7 of fresh Swift source.")
