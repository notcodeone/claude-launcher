import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Иконки профиля — по ключу, который хранится в profiles.json.
/// Порядок — порядок в сетке выбора.
const profileIcons = <String, IconData>{
  'folder': LucideIcons.folder,
  'briefcase': LucideIcons.briefcase,
  'house': LucideIcons.house,
  'code': LucideIcons.braces,
  'terminal': LucideIcons.squareTerminal,
  'rocketLaunch': LucideIcons.rocket,
  'lightbulb': LucideIcons.lightbulb,
  'chartBar': LucideIcons.chartColumn,
  'dollar': LucideIcons.circleDollarSign,
  'shoppingBag': LucideIcons.shoppingBag,
  'book': LucideIcons.book,
  'graduationCap': LucideIcons.graduationCap,
  'notebook': LucideIcons.notebookPen,
  'pencil': LucideIcons.pencil,
  'penNib': LucideIcons.penTool,
  'paintBrush': LucideIcons.paintbrush,
  'palette': LucideIcons.palette,
  'camera': LucideIcons.camera,
  'music': LucideIcons.music,
  'popcorn': LucideIcons.popcorn,
  'gameController': LucideIcons.gamepad2,
  'coffee': LucideIcons.coffee,
  'airplane': LucideIcons.plane,
  'globe': LucideIcons.globe,
  'heart': LucideIcons.heart,
  'pawPrint': LucideIcons.pawPrint,
  'plant': LucideIcons.sprout,
  'flask': LucideIcons.flaskConical,
  'brain': LucideIcons.brain,
  'star': LucideIcons.star,
};

IconData profileIcon(String key) => profileIcons[key] ?? LucideIcons.folder;
