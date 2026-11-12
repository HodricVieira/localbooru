library tag_manager;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:localbooru/api/index.dart';
import 'package:localbooru/utils/constants.dart';
import 'package:localbooru/utils/misc.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:collection/collection.dart';

part 'autotag.dart';
part 'interfaces.dart';
part 'match.dart';

