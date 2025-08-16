
// ignore_for_file: prefer_const_constructors
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FuelApp());
}

class FuelApp extends StatelessWidget {
  const FuelApp({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      scaffoldBackgroundColor: const Color(0xFFEAF6EA), // verde pastello chiaro
      primaryColor: Colors.green,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 16),
      ),
    );

    return MaterialApp(
      title: 'Calcolo Carburante',
      theme: theme,
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

enum FuelType { benzina, diesel, gpl, metano }
enum RoadType { autostrada, citta, misto }
enum Traffic { normale, moderato, intenso }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _origin = TextEditingController();
  final _destination = TextEditingController();
  final _distanceKm = TextEditingController(); // manual override
  final _pricePerUnit = TextEditingController(); // €/L (o €/kg per metano)

  FuelType _fuel = FuelType.benzina;
  RoadType _road = RoadType.autostrada;
  Traffic _traffic = Traffic.normale;

  double? _lastTotal;
  double? _lastFuelCost;
  double? _lastTolls;
  double? _lastLiters;
  double? _lastKm;

  bool _loadingDistance = false;
  final NumberFormat currency = NumberFormat.simpleCurrency(locale: 'it_IT', name: '€');

  @override
  void initState() {
    super.initState();
    _pricePerUnit.text = "1,85"; // default esempio
  }

  @override
  void dispose() {
    _origin.dispose();
    _destination.dispose();
    _distanceKm.dispose();
    _pricePerUnit.dispose();
    super.dispose();
  }

  double _parseNum(String s) {
    // accetta virgola o punto
    return double.tryParse(s.replaceAll(',', '.')) ?? 0.0;
  }

  double _baseConsumptionPer100(FuelType f) {
    switch (f) {
      case FuelType.benzina:
        return 7.0;
      case FuelType.diesel:
        return 5.5;
      case FuelType.gpl:
        return 8.0;
      case FuelType.metano:
        return 4.5; // kg/100km
    }
  }

  double _roadFactor(RoadType r) {
    switch (r) {
      case RoadType.autostrada:
        return 1.10; // +10%
      case RoadType.citta:
        return 1.20; // +20%
      case RoadType.misto:
        return 1.00;
    }
  }

  double _trafficFactor(Traffic t) {
    switch (t) {
      case Traffic.normale:
        return 1.00;
      case Traffic.moderato:
        return 1.10;
      case Traffic.intenso:
        return 1.20;
    }
  }

  double _tollPerKm(RoadType r) {
    switch (r) {
      case RoadType.autostrada:
        return 0.09; // stima media € / km
      case RoadType.misto:
        return 0.045;
      case RoadType.citta:
        return 0.0;
    }
  }

  Future<void> _fetchDistance() async {
    final origins = _origin.text.trim();
    final dest = _destination.text.trim();
    if (origins.isEmpty || dest.isEmpty) {
      _snack('Inserisci Partenza e Destinazione');
      return;
    }
    if (Config.googleApiKey.trim().isEmpty) {
      _snack('API Key mancante: imposta la tua chiave in lib/config.dart');
      return;
    }
    setState(() => _loadingDistance = true);
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/distancematrix/json'
        '?units=metric&origins=${Uri.encodeComponent(origins)}'
        '&destinations=${Uri.encodeComponent(dest)}'
        '&key=${Config.googleApiKey}',
      );
      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (data['rows'] != null &&
            data['rows'][0]['elements'] != null &&
            data['rows'][0]['elements'][0]['status'] == 'OK') {
          final meters = data['rows'][0]['elements'][0]['distance']['value'] as num;
          final km = meters / 1000.0;
          _distanceKm.text = km.toStringAsFixed(1);
          _snack('Distanza impostata: ${km.toStringAsFixed(1)} km');
        } else {
          _snack('Impossibile ottenere la distanza (verifica indirizzi e Key)');
        }
      } else {
        _snack('Errore rete: ${resp.statusCode}');
      }
    } catch (e) {
      _snack('Errore: $e');
    } finally {
      if (mounted) setState(() => _loadingDistance = false);
    }
  }

  Future<void> _calculate() async {
    final km = _parseNum(_distanceKm.text);
    final price = _parseNum(_pricePerUnit.text);
    if (km <= 0) {
      _snack('Inserisci la distanza in km (o usa Partenza/Destinazione)');
      return;
    }
    if (price <= 0) {
      _snack('Inserisci il prezzo del carburante');
      return;
    }
    final base = _baseConsumptionPer100(_fuel);
    final cons = base * _roadFactor(_road) * _trafficFactor(_traffic); // per 100 km
    final liters = cons * (km / 100.0);
    final fuelCost = liters * price;
    final tolls = km * _tollPerKm(_road);
    final total = fuelCost + tolls;

    setState(() {
      _lastKm = km;
      _lastLiters = liters;
      _lastFuelCost = fuelCost;
      _lastTolls = tolls;
      _lastTotal = total;
    });

    await Storage.addHistory(Trip(
      origin: _origin.text.trim(),
      destination: _destination.text.trim(),
      km: km,
      fuelType: _fuel.name,
      roadType: _road.name,
      traffic: _traffic.name,
      pricePerUnit: price,
      liters: liters,
      fuelCost: fuelCost,
      tolls: tolls,
      total: total,
      ts: DateTime.now().toIso8601String(),
    ));
  }

  Future<void> _addFavorite() async {
    if (_lastTotal == null) {
      _snack('Calcola prima il costo');
      return;
    }
    await Storage.addFavorite(Favorite(
      origin: _origin.text.trim(),
      destination: _destination.text.trim(),
      km: _lastKm ?? _parseNum(_distanceKm.text),
      total: _lastTotal!,
      createdAt: DateTime.now().toIso8601String(),
    ));
    _snack('Aggiunto ai Preferiti');
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Calcolo Carburante'),
        backgroundColor: Colors.green.shade600,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _origin,
              decoration: InputDecoration(
                labelText: 'Partenza',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _destination,
              decoration: InputDecoration(
                labelText: 'Destinazione',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _loadingDistance ? null : _fetchDistance,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                  shape: StadiumBorder(),
                ),
                icon: _loadingDistance
                    ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(Icons.route),
                label: Text('Calcola distanza'),
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _distanceKm,
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Distanza (km)',
                hintText: 'Es. 225',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: _pricePerUnit,
              keyboardType: TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Prezzo carburante (€/L o €/kg)',
                hintText: 'Es. 1,85',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _Dropdown<FuelType>(
                  label: 'Carburante',
                  value: _fuel,
                  items: const {
                    FuelType.benzina: 'Benzina',
                    FuelType.diesel: 'Diesel',
                    FuelType.gpl: 'GPL',
                    FuelType.metano: 'Metano',
                  },
                  onChanged: (v) => setState(() => _fuel = v!),
                )),
                SizedBox(width: 12),
                Expanded(child: _Dropdown<RoadType>(
                  label: 'Tipo strada',
                  value: _road,
                  items: const {
                    RoadType.autostrada: 'Autostrada',
                    RoadType.citta: 'Città',
                    RoadType.misto: 'Misto',
                  },
                  onChanged: (v) => setState(() => _road = v!),
                )),
              ],
            ),
            SizedBox(height: 12),
            _Dropdown<Traffic>(
              label: 'Traffico',
              value: _traffic,
              items: const {
                Traffic.normale: 'Normale',
                Traffic.moderato: 'Moderato',
                Traffic.intenso: 'Intenso',
              },
              onChanged: (v) => setState(() => _traffic = v!),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _calculate,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: const StadiumBorder(),
              ),
              child: Text('Calcola', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            SizedBox(height: 16),
            if (_lastTotal != null) Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Text('Costo Totale', style: TextStyle(fontSize: 16, color: Colors.grey[700])),
                    SizedBox(height: 8),
                    Text(
                      currency.format(_lastTotal),
                      style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: Colors.green.shade800),
                    ),
                    SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.local_gas_station, color: Colors.green.shade700),
                        SizedBox(width: 6),
                        Text('Stima', style: TextStyle(color: Colors.grey[700])),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _addFavorite,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.green.shade700, width: 1.5),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: Icon(Icons.star, color: Colors.green.shade700),
                    label: Text('Aggiungi ai Preferiti', style: TextStyle(color: Colors.green.shade700)),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryPage())),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.green.shade700, width: 1.5),
                      shape: const StadiumBorder(),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    icon: Icon(Icons.history, color: Colors.green.shade700),
                    label: Text('Cronologia', style: TextStyle(color: Colors.green.shade700)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T?> onChanged;
  const _Dropdown({required this.label, required this.value, required this.items, required this.onChanged, super.key});

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: items.entries
              .map((e) => DropdownMenuItem<T>(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class Trip {
  final String origin;
  final String destination;
  final double km;
  final String fuelType;
  final String roadType;
  final String traffic;
  final double pricePerUnit;
  final double liters;
  final double fuelCost;
  final double tolls;
  final double total;
  final String ts;

  Trip({
    required this.origin,
    required this.destination,
    required this.km,
    required this.fuelType,
    required this.roadType,
    required this.traffic,
    required this.pricePerUnit,
    required this.liters,
    required this.fuelCost,
    required this.tolls,
    required this.total,
    required this.ts,
  });

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'destination': destination,
    'km': km,
    'fuelType': fuelType,
    'roadType': roadType,
    'traffic': traffic,
    'pricePerUnit': pricePerUnit,
    'liters': liters,
    'fuelCost': fuelCost,
    'tolls': tolls,
    'total': total,
    'ts': ts,
  };

  static Trip fromJson(Map<String, dynamic> j) => Trip(
    origin: j['origin'] ?? '',
    destination: j['destination'] ?? '',
    km: (j['km'] ?? 0).toDouble(),
    fuelType: j['fuelType'] ?? 'benzina',
    roadType: j['roadType'] ?? 'misto',
    traffic: j['traffic'] ?? 'normale',
    pricePerUnit: (j['pricePerUnit'] ?? 0).toDouble(),
    liters: (j['liters'] ?? 0).toDouble(),
    fuelCost: (j['fuelCost'] ?? 0).toDouble(),
    tolls: (j['tolls'] ?? 0).toDouble(),
    total: (j['total'] ?? 0).toDouble(),
    ts: j['ts'] ?? DateTime.now().toIso8601String(),
  );
}

class Favorite {
  final String origin;
  final String destination;
  final double km;
  final double total;
  final String createdAt;

  Favorite({
    required this.origin,
    required this.destination,
    required this.km,
    required this.total,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'destination': destination,
    'km': km,
    'total': total,
    'createdAt': createdAt,
  };

  static Favorite fromJson(Map<String, dynamic> j) => Favorite(
    origin: j['origin'] ?? '',
    destination: j['destination'] ?? '',
    km: (j['km'] ?? 0).toDouble(),
    total: (j['total'] ?? 0).toDouble(),
    createdAt: j['createdAt'] ?? DateTime.now().toIso8601String(),
  );
}

class Storage {
  static const _kHistory = 'history_v1';
  static const _kFavs = 'favorites_v1';

  static Future<void> addHistory(Trip t) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kHistory) ?? [];
    list.insert(0, jsonEncode(t.toJson()));
    await prefs.setStringList(_kHistory, list.take(50).toList());
  }

  static Future<List<Trip>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kHistory) ?? [];
    return list.map((s) => Trip.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> addFavorite(Favorite f) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kFavs) ?? [];
    list.insert(0, jsonEncode(f.toJson()));
    await prefs.setStringList(_kFavs, list.take(50).toList());
  }

  static Future<List<Favorite>> getFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_kFavs) ?? [];
    return list.map((s) => Favorite.fromJson(jsonDecode(s))).toList();
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<Trip>> _future;

  @override
  void initState() {
    super.initState();
    _future = Storage.getHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cronologia'),
        backgroundColor: Colors.green.shade600,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<List<Trip>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          if (items.isEmpty) {
            return Center(child: Text('Nessun viaggio calcolato ancora.'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => Divider(),
            itemBuilder: (_, i) {
              final t = items[i];
              return ListTile(
                leading: Icon(Icons.directions_car, color: Colors.green.shade700),
                title: Text('${t.origin.isEmpty ? "—" : t.origin} → ${t.destination.isEmpty ? "—" : t.destination}'),
                subtitle: Text('${t.km.toStringAsFixed(1)} km  •  ${t.fuelType}  •  ${t.roadType}'),
                trailing: Text(NumberFormat.simpleCurrency(locale: 'it_IT', name: '€').format(t.total)),
              );
            },
          );
        },
      ),
    );
  }
}
