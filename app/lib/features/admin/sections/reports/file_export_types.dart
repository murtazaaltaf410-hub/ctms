/// What happened to an exported file.
enum ExportOutcome {
  /// The browser started a file download.
  saved,

  /// No file save is available here; the text was copied to the clipboard.
  copied,
}

typedef TextFileSaver =
    Future<ExportOutcome> Function({
      required String filename,
      required String content,
      required String mimeType,
    });
