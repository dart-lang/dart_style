/// Determines the set of Levenshtein edits needed to convert [before] into
/// [after].
///
/// Returns the list of differences.
/// From: https://en.wikipedia.org/wiki/Levenshtein_distance
List<Diff<T>> calculateDiffs<T>(List<T> before, List<T> after) {
  var matrix = _Matrix(before.length + 1, after.length + 1);

  // Initialize the first row of distances. It's the number of edits to get
  // from an empty expected list to the prefix of the actual list of a given
  // length, which is just that many inserts.
  for (var x = 0; x < before.length + 1; x++) {
    matrix.set(x, 0, x);
  }

  // For each prefix of the after list, calculate the edit distances to reach
  // it from each prefix of the before list. Each row is calculated from the
  // previous row.
  for (var y = 1; y < after.length + 1; y++) {
    // The first element of v1 is A[i+1][0].
    // The edit distance is delete (i+1) elements from s to match empty t.
    matrix.set(0, y, y);

    // Use formula to fill in the rest of the row.
    for (var x = 1; x < before.length + 1; x++) {
      var cost = after[y - 1] == before[x - 1] ? 0 : 1;

      var left = matrix.get(x - 1, y) + 1;
      var up = matrix.get(x, y - 1) + 1;
      var diagonal = matrix.get(x - 1, y - 1) + cost;
      matrix.set(x, y, _min3(left, up, diagonal));
    }
  }

  var x = matrix.width - 1;
  var y = matrix.height - 1;
  var edits = <Diff<T>>[];
  while (x > 0 || y > 0) {
    var here = matrix.get(x, y);

    var left = x > 0 ? matrix.get(x - 1, y) : here + 999;
    var up = y > 0 ? matrix.get(x, y - 1) : here + 999;
    var diagonal = x > 0 && y > 0 ? matrix.get(x - 1, y - 1) : here + 999;

    if (diagonal <= left && diagonal <= up) {
      // We're consuming an element from both.
      if (diagonal != here) {
        // And they didn't match, so substitute.
        edits.add(SubstituteDiff(before[x - 1], after[y - 1]));
      }
      x--;
      y--;
    } else if (left <= up) {
      // We're consuming an element from before, so there is a new element.
      edits.add(InsertDiff(before[x - 1]));
      x--;
    } else {
      // We're consuming an element from after, so there is a removed element.
      edits.add(DeleteDiff(after[y - 1]));
      y--;
    }
  }

  return edits.reversed.toList();
}

/// Determines the number of Levenshtein edits needed to convert [before] into
/// [after].
///
/// Treates a substitution as a single edit and not a delete + insert.
int countDifferences<T>(
  List<T> before,
  List<T> after, {
  bool Function(T, T)? compare,
}) => calculateDiffs(before, after).length;

sealed class Diff<T> {}

final class SubstituteDiff<T> extends Diff<T> {
  final T before;
  final T after;

  SubstituteDiff(this.before, this.after);
}

final class InsertDiff<T> extends Diff<T> {
  final T after;

  InsertDiff(this.after);
}

final class DeleteDiff<T> extends Diff<T> {
  final T before;

  DeleteDiff(this.before);
}

/// Returns the minimum of [a], [b], and [c].
int _min3(int a, int b, int c) {
  if (a < b) {
    return a < c ? a : c;
  } else {
    return b < c ? b : c;
  }
}

/// A two-dimensional fixed-size matrix of integers.
class _Matrix {
  /// The number of elements in a row of the matrix.
  final int width;

  /// The number of elements in a column of the matrix.
  final int height;

  final List<int> _elements;

  /// Creates a new matrix with [width], [height] value initialized to `0`.
  _Matrix(this.width, this.height) : _elements = List.filled(width * height, 0);

  /// Gets the element in the array at [x], [y].
  int get(int x, int y) => _elements[y * width + x];

  /// Sets the value in the matrix at [x], [y] to [value].
  void set(int x, int y, int value) {
    _elements[y * width + x] = value;
  }
}
