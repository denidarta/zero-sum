import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'app.dart';
import 'db.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sql = await openDatabase(
    p.join(await getDatabasesPath(), 'zero_sum.db'),
    version: 1,
    onCreate: Db.create,
  );
  final db = await Db.open(sql);
  db
    ..connect()
    ..sync();
  runApp(ZeroSumApp(db: db));
}
