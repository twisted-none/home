import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'api.dart';
import 'ui.dart';

const uuid = Uuid();

String itemGroup(Json item) {
  final chain = chainNames[item['chain']] ?? item['chain'];
  final city = cityNames[item['city']] ?? item['city'];
  final store = item['store_name'];
  return store == null ? '$chain · $city' : '$chain · $city · $store';
}

String quantityText(int milliunits) => (milliunits / 1000)
    .toStringAsFixed(3)
    .replaceFirst(RegExp(r'\.?0+$'), '')
    .replaceFirst('.', ',');

Future<void> openSource(BuildContext context, String url) async {
  try {
    if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        ) &&
        context.mounted) {
      toast(context, 'Не удалось открыть сайт.');
    }
  } catch (_) {
    if (context.mounted) toast(context, 'Не удалось открыть сайт.');
  }
}

class ShoppingView extends StatelessWidget {
  const ShoppingView({
    super.key,
    required this.items,
    required this.draft,
    required this.busy,
    required this.onCatalogs,
    required this.onPublish,
    required this.onRemove,
    required this.onBought,
  });

  final List<Json> items;
  final List<Json> draft;
  final bool busy;
  final VoidCallback onCatalogs;
  final VoidCallback onPublish;
  final ValueChanged<Json> onRemove;
  final ValueChanged<Json> onBought;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(18),
    children: [
      FilledButton.icon(
        onPressed: busy ? null : onCatalogs,
        icon: const Icon(Icons.storefront_outlined),
        label: const Text('Открыть каталоги'),
      ),
      if (draft.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Ваш черновик', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text(
          'Семья увидит товары после отправки.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 8),
        ...groups(context, draft, personal: true),
        OutlinedButton.icon(
          onPressed: busy ? null : onPublish,
          icon: const Icon(Icons.send_outlined),
          label: const Text('В общий список'),
        ),
      ],
      const SizedBox(height: 20),
      Text('Общий список', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      if (items.isEmpty)
        const EmptyMessage(
          icon: Icons.shopping_bag_outlined,
          title: 'Список пока пуст',
          detail: 'Добавьте товары из каталогов и отправьте их семье.',
        )
      else
        ...groups(context, items, personal: false),
    ],
  );

  List<Widget> groups(
    BuildContext context,
    List<Json> items, {
    required bool personal,
  }) {
    final grouped = <String, List<Json>>{};
    for (final item in items) {
      grouped.putIfAbsent(itemGroup(item), () => []).add(item);
    }
    return [
      for (final group in grouped.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Panel(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.key,
                  style: const TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                for (final item in group.value)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      item['name'] as String,
                      style: TextStyle(
                        decoration: item['bought'] == true
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      '${quantityText(item['quantity_milliunits'] as int)} ${item['unit']} · '
                      '${priceText(item['price_kopecks'] as int)} / ${item['unit']}',
                    ),
                    leading: personal
                        ? null
                        : Checkbox(
                            value: item['bought'] as bool,
                            semanticLabel: 'Куплено, ${item['name']}',
                            onChanged: busy ? null : (_) => onBought(item),
                          ),
                    trailing: personal
                        ? IconButton(
                            onPressed: busy ? null : () => onRemove(item),
                            icon: const Icon(Icons.remove_circle_outline),
                            tooltip: 'Удалить из черновика',
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
    ];
  }
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.api});

  final FamilyApi api;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  late Future<dynamic> data;

  @override
  void initState() {
    super.initState();
    data = widget.api.get('/catalogs');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Каталоги')),
    body: FutureBuilder<dynamic>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [
              ErrorNotice(
                error: snapshot.error!,
                retry: () => setState(() => data = widget.api.get('/catalogs')),
              ),
            ],
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final result = snapshot.data as Json;
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              cityNames[result['city']]!,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            for (final chain in rows(result['chains'])) ...[
              Panel(
                padding: EdgeInsets.zero,
                child: ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  leading: const Icon(Icons.storefront_outlined),
                  title: Text(chain['name'] as String),
                  subtitle: Text(
                    rows(chain['catalogs']).isEmpty
                        ? 'Цены пока не загружены'
                        : 'Открыть каталог',
                  ),
                  children: [
                    for (final catalog in rows(chain['catalogs']))
                      ListTile(
                        title: Text(
                          catalog['store_name'] as String? ??
                              'Каталог для города',
                        ),
                        subtitle: Text(
                          catalog['stale'] == true
                              ? 'Данные могут быть устаревшими'
                              : (catalog['partial'] == true
                                    ? 'Частичный ассортимент'
                                    : 'Товары и цены'),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ProductsScreen(
                              api: widget.api,
                              name: chain['name'] as String,
                              catalog: catalog,
                            ),
                          ),
                        ),
                      ),
                    ListTile(
                      leading: const Icon(Icons.open_in_new),
                      title: const Text('Сайт магазина'),
                      onTap: () =>
                          openSource(context, chain['source_url'] as String),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        );
      },
    ),
  );
}

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({
    super.key,
    required this.api,
    required this.name,
    required this.catalog,
  });

  final FamilyApi api;
  final String name;
  final Json catalog;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final search = TextEditingController();
  late Json catalog;
  List<Json> products = [];
  int? next;
  int requestVersion = 0;
  bool loading = true;
  bool adding = false;
  Object? error;
  String query = '';

  @override
  void initState() {
    super.initState();
    catalog = widget.catalog;
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load({int offset = 0}) async {
    final version = ++requestVersion;
    setState(() {
      loading = true;
      error = null;
      if (offset == 0) {
        products = [];
        next = null;
        query = search.text.trim();
      }
    });
    try {
      final path = Uri(
        path: '/catalogs/${catalog['id']}/products',
        queryParameters: {'q': query, 'offset': '$offset'},
      );
      final data = await widget.api.get(path.toString()) as Json;
      if (!mounted || version != requestVersion) return;
      setState(() {
        catalog = data['catalog'] as Json;
        products = [...products, ...rows(data['products'])];
        next = data['next_offset'] as int?;
      });
    } catch (failure) {
      if (mounted && version == requestVersion) setState(() => error = failure);
    } finally {
      if (mounted && version == requestVersion) setState(() => loading = false);
    }
  }

  Future<void> add(Json product) async {
    if (adding) return;
    setState(() => adding = true);
    try {
      final quantity = await showDialog<int>(
        context: context,
        builder: (context) => QuantityDialog(product: product),
      );
      if (quantity == null || !mounted) return;
      await widget.api.send(
        'POST',
        '/shopping/draft',
        retry: true,
        body: {
          'product_id': product['id'],
          'request_id': uuid.v4(),
          'quantity_milliunits': quantity,
        },
      );
      if (mounted) toast(context, 'Товар добавлен в черновик');
    } catch (error) {
      if (mounted) toast(context, error);
    } finally {
      if (mounted) setState(() => adding = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.name)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: TextField(
            controller: search,
            textInputAction: TextInputAction.search,
            maxLength: 100,
            onSubmitted: (_) => load(),
            decoration: InputDecoration(
              labelText: 'Поиск по названию',
              counterText: '',
              suffixIcon: IconButton(
                onPressed: () => load(),
                icon: const Icon(Icons.search),
                tooltip: 'Найти',
              ),
            ),
          ),
        ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
            itemCount: products.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                final updated = moscowTime(catalog['updated_at'] as String);
                final store = catalog['store_name'] as String?;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (store != null) Text(store),
                    Text(
                      'Обновлено ${ruDate(updated)} в ${clockTime(updated)}',
                      style: TextStyle(
                        color: catalog['stale'] == true ? warm : muted,
                      ),
                    ),
                    if (catalog['partial'] == true)
                      const Text('Частичный ассортимент'),
                    if (catalog['stale'] == true)
                      const Text(
                        'Цены могут быть устаревшими.',
                        style: TextStyle(color: warm),
                      ),
                    TextButton.icon(
                      onPressed: () =>
                          openSource(context, catalog['source_url'] as String),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Источник цен'),
                    ),
                  ],
                );
              }
              if (index > products.length) {
                if (error != null) {
                  return ErrorNotice(
                    error: error!,
                    retry: () => load(offset: next ?? 0),
                  );
                }
                if (!loading && next != null) {
                  return OutlinedButton(
                    onPressed: () => load(offset: next!),
                    child: const Text('Показать ещё'),
                  );
                }
                return !loading && products.isEmpty
                    ? const Text('Товары не найдены.')
                    : const SizedBox.shrink();
              }
              final product = products[index - 1];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(product['name'] as String),
                subtitle: Text(
                  '${priceText(product['price_kopecks'] as int)} / ${product['unit']} · ${product['category']}',
                ),
                trailing: IconButton.filledTonal(
                  icon: const Icon(Icons.add),
                  tooltip: 'Добавить в черновик',
                  onPressed: adding ? null : () => add(product),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class QuantityDialog extends StatefulWidget {
  const QuantityDialog({super.key, required this.product});

  final Json product;

  @override
  State<QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<QuantityDialog> {
  final input = TextEditingController(text: '1');
  final form = GlobalKey<FormState>();

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  int? parse() {
    final text = input.text.trim();
    if (!RegExp(r'^\d{1,3}([.,]\d{1,3})?$').hasMatch(text)) return null;
    final result = (double.parse(text.replaceFirst(',', '.')) * 1000).round();
    return result > 0 && result <= 999000 ? result : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.product['name'] as String),
    content: Form(
      key: form,
      child: TextFormField(
        controller: input,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Количество, ${widget.product['unit']}',
        ),
        validator: (_) =>
            parse() == null ? 'Введите число от 0,001 до 999' : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) Navigator.pop(context, parse());
        },
        child: const Text('Добавить'),
      ),
    ],
  );
}
