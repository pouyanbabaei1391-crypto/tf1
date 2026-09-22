import 'package:flutter/material.dart';

import 'core/app_controller.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppController.create();
  runApp(NexaDropApp(controller: controller));
}
