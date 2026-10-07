/// An inclusive byte range, `[start, end]`, used to plan and issue HTTP
/// `Range` requests for a single download chunk.
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;

  /// Inclusive end offset.
  final int end;

  int get length => end - start + 1;

  List<int> toJson() => [start, end];

  factory ByteRange.fromJson(List<dynamic> json) =>
      ByteRange(json[0] as int, json[1] as int);

  @override
  bool operator ==(Object other) =>
      other is ByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'ByteRange($start-$end)';
}
