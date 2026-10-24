import 'package:flutter/material.dart';
import 'features/editor/editor_screen.dart';
import 'features/export/export_screen.dart';

void main() {
  runApp(const EditVideoApp());
}

class EditVideoApp extends StatelessWidget {
  const EditVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edit Video',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const EditorScreen(),
        '/export': (context) => const ExportScreen(),
      },
    );
  }
}
