import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/import/epg_pipeline.dart';

void main() {
  String d(String s, {int skipped = 0}) {
    final b = utf8.encode(s);
    return describeEmptyGuide(b, b.length, skipped);
  }

  test('explains empty guide responses', () {
    expect(describeEmptyGuide(const [], 0, 0), contains('returned nothing'));
    expect(d('  \n'), contains('empty document'));
    expect(d('{"user_info":{"auth":0}}'), contains('rejected the login'));
    expect(d('{"error":"x"}'), contains('JSON'));
    expect(d('<!DOCTYPE html><html>'), contains('web page'));
    expect(d('<?xml version="1.0"?><tv></tv>'), contains('no channels'));
    expect(d('<tv><programme start="2001"/></tv>', skipped: 3), contains('out of date'));
    expect(describeEmptyGuide([0xFF, 0xFE, 0x3C, 0], 4, 0), contains('UTF-16'));
    expect(d('garbage'), contains('starts with: garbage'));
  });
}
