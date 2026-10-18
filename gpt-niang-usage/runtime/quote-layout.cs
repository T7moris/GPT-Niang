#pragma warning disable 0618
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace GptNiang {
    public sealed class QuoteLayoutResult {
        public double fontSize { get; set; }
        public double width { get; set; }
        public double lineHeight { get; set; }
        public double offsetX { get; set; }
        public double offsetY { get; set; }
        public int lines { get; set; }
        public double score { get; set; }
    }

    // Compile once at startup. Candidate ranking needs selection rectangles,
    // while only the best viable candidates need expensive glyph outlines.
    public static class QuoteLayout {
        private sealed class Candidate {
            public FormattedText formatted;
            public double size, width, score;
            public int lines, index;
        }

        private static Candidate Rank(string value, TextBlock text, Typeface face, double size, double width, int expectedLines, int index) {
            var formatted = new FormattedText(value, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, size, text.Foreground);
            formatted.MaxTextWidth = width;
            formatted.TextAlignment = TextAlignment.Center;
            formatted.LineHeight = size * 1.15;
            if (formatted.Height > 134) return null;
            // One full selection replaces a BuildHighlightGeometry call for
            // every character of every candidate. Scan its row midpoints.
            var selection = formatted.BuildHighlightGeometry(new Point(0, 0), 0, value.Length);
            if (selection == null || selection.Bounds.IsEmpty) return null;
            var polygons = new List<List<Point>>();
            foreach (var figure in selection.GetFlattenedPathGeometry().Figures) {
                var polygon = new List<Point> { figure.StartPoint };
                foreach (var segment in figure.Segments) {
                    var line = segment as LineSegment;
                    if (line != null) polygon.Add(line.Point);
                    var polyline = segment as PolyLineSegment;
                    if (polyline != null) foreach (var point in polyline.Points) polygon.Add(point);
                }
                polygons.Add(polygon);
            }
            int count = (int)Math.Round(formatted.Height / formatted.LineHeight), lines = 0;
            double maximum = 0, minimum = Double.PositiveInfinity;
            for (int i = 0; i < count; i++) {
                double y = (i + 0.5) * formatted.LineHeight;
                double left = Double.PositiveInfinity, right = Double.NegativeInfinity;
                foreach (var polygon in polygons) {
                    for (int j = 0; j < polygon.Count; j++) {
                        var a = polygon[j]; var b = polygon[(j + 1) % polygon.Count];
                        if ((a.Y <= y && b.Y > y) || (b.Y <= y && a.Y > y)) {
                            double x = a.X + (y - a.Y) * (b.X - a.X) / (b.Y - a.Y);
                            left = Math.Min(left, x); right = Math.Max(right, x);
                        }
                    }
                }
                lines++;
                double length = right >= left ? right - left : 0;
                maximum = Math.Max(maximum, length); minimum = Math.Min(minimum, length);
            }
            if (expectedLines > 0 && lines != expectedLines) return null;
            double imbalance = maximum > 0 ? 1 - minimum / maximum : 0;
            double score = size * 10 - Math.Max(0, lines - 2) * 26 - (lines - 1) * 8 - imbalance * 55;
            return new Candidate { formatted = formatted, size = size, width = width, score = score, lines = lines, index = index };
        }

        private static QuoteLayoutResult Validate(Candidate candidate) {
            if (candidate == null) return null;
            var geometry = candidate.formatted.BuildGeometry(new Point(155 - candidate.width / 2, 85 - candidate.formatted.Height / 2));
            if (geometry.Bounds.IsEmpty) return null;
            double x = 155 - (geometry.Bounds.Left + geometry.Bounds.Width / 2);
            double y = 85 - (geometry.Bounds.Top + geometry.Bounds.Height / 2);
            geometry.Transform = new TranslateTransform(x, y);
            var interior = new EllipseGeometry(new Point(155, 85), 116, 67);
            if (interior.FillContainsWithDetail(geometry) != IntersectionDetail.FullyContains) return null;
            return new QuoteLayoutResult { fontSize = candidate.size, width = candidate.width, lineHeight = candidate.size * 1.15,
                offsetX = x, offsetY = y, lines = candidate.lines, score = candidate.score };
        }

        public static QuoteLayoutResult Get(string value, TextBlock text, int expectedLines, double[] hint) {
            var face = new Typeface(text.FontFamily, text.FontStyle, text.FontWeight, text.FontStretch);
            if (hint != null && hint.Length == 2 && hint[0] >= 10 && hint[0] <= 32 && hint[1] >= 140 && hint[1] <= 236) {
                var reviewed = Validate(Rank(value, text, face, hint[0], hint[1], expectedLines, 0));
                if (reviewed != null) return reviewed;
            }
            // Preserve the original preference for readable 18+ point layouts.
            foreach (var range in new[] { new[] { 32, 18 }, new[] { 17, 6 } }) {
                var candidates = new List<Candidate>();
                for (int size = range[0]; size >= range[1]; size--) {
                    foreach (int width in new[] { 236, 228, 220, 212, 204, 196, 188, 180, 172, 164, 156, 148, 140 }) {
                        var candidate = Rank(value, text, face, size, width, expectedLines, candidates.Count);
                        if (candidate != null) candidates.Add(candidate);
                    }
                }
                candidates.Sort((a, b) => { int comparison = Math.Round(b.score, 5).CompareTo(Math.Round(a.score, 5)); return comparison == 0 ? a.index.CompareTo(b.index) : comparison; });
                foreach (var candidate in candidates) { var result = Validate(candidate); if (result != null) return result; }
            }
            throw new InvalidOperationException("Quote cannot fit inside the bubble");
        }
    }
}
