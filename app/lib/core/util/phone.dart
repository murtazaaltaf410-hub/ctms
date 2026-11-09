/// Normalises a typed phone number to E.164; Indian numbers by default.
/// `98765 43210` gives `+919876543210`. Null when it cannot be valid.
String? normalisePhone(String input, {String defaultCountryCode = '+91'}) {
  var digits = input.replaceAll(RegExp(r'[\s\-().]'), '');
  if (digits.startsWith('00')) digits = '+${digits.substring(2)}';
  if (!digits.startsWith('+')) {
    digits = digits.replaceFirst(RegExp('^0+'), '');
    digits = '$defaultCountryCode$digits';
  }
  return RegExp(r'^\+[1-9][0-9]{6,14}$').hasMatch(digits) ? digits : null;
}
