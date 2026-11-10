/// Google map styles for the CTMS maps: muted land, olive-tinted water and
/// parks, softer roads, no business clutter. Nearby places (schools, hospitals,
/// worship, parks) keep their text labels because students look for them
/// around the route; only their pin icons are removed.
abstract final class TransitMapStyle {
  static const light = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f3f1e8"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#5d6b5b"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#fbfaf5"},{"weight":3}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#d8dccb"}]},
  {"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#ece9dc"}]},
  {"featureType":"landscape.natural","elementType":"geometry","stylers":[{"color":"#eef0e0"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#6f7d63"}]},
  {"featureType":"poi.business","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#dfe7c4"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#5a7a2a"}]},
  {"featureType":"poi.school","elementType":"geometry","stylers":[{"color":"#e7e9cf"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#e4e2d4"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a9585"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#fffef9"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#f2ecd2"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#e2d9b4"}]},
  {"featureType":"road.local","elementType":"labels","stylers":[{"visibility":"simplified"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#c9d9b9"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#5a7a2a"}]}
]
''';

  static const dark = '''
[
  {"elementType":"geometry","stylers":[{"color":"#16211a"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#9fb09c"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#121a14"},{"weight":3}]},
  {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#2c3b2e"}]},
  {"featureType":"administrative.land_parcel","stylers":[{"visibility":"off"}]},
  {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#1a271e"}]},
  {"featureType":"landscape.natural","elementType":"geometry","stylers":[{"color":"#17241a"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#8ea28b"}]},
  {"featureType":"poi.business","stylers":[{"visibility":"off"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1f3322"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#a3c964"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#26352a"}]},
  {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#1c281f"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#7f927c"}]},
  {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#2d3f31"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#364a38"}]},
  {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#243227"}]},
  {"featureType":"road.local","elementType":"labels","stylers":[{"visibility":"simplified"}]},
  {"featureType":"transit","stylers":[{"visibility":"off"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#1d3a2c"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#7fa66a"}]}
]
''';
}
