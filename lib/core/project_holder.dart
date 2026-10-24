import '../models/capcut_models.dart';

/// Partage d'état du projet actuel entre les écrans (éditeur → export).
/// Évite les passages de paramètres complexes et les blocages de navigation.
class ProjectHolder {
  ProjectHolder._();
  static Project? current;
}