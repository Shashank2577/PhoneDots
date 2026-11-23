import 'generated/catalog.g.dart';
import 'model_spec.dart';

/// The models every app on the platform can use. The shared list comes from
/// catalog/models.json; an app may add private entries, but a model two apps
/// need belongs in the shared catalog so it is downloaded once.
class ModelCatalog {
  ModelCatalog({List<ModelSpec> extra = const []}) : all = List.unmodifiable([...generatedCatalog, ...extra]) {
    final seen = <String>{};
    for (final m in all) {
      if (!seen.add(m.id)) throw ArgumentError('Duplicate model id ${m.id}');
    }
  }

  final List<ModelSpec> all;

  ModelSpec? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  ModelSpec require(String id) => byId(id) ?? (throw ArgumentError('Unknown model $id. Add it to catalog/models.json.'));

  List<ModelSpec> runnableOn(String platform) => all.where((m) => m.runsOn(platform)).toList();
}
