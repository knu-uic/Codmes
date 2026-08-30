using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Codmes.Windows;

public sealed class PdfAnnotationCanvas : FrameworkElement
{
    public enum AnnotationTool { Pan, Pen, Rectangle, Text }

    public AnnotationTool Tool { get; set; } = AnnotationTool.Pan;
    public Action<double, double>? TextRequested { get; set; }
    public JsonObject Document { get; private set; } = new();
    private BitmapSource? image;
    private int pageIndex;
    private Rect pageRect;
    private JsonArray? activePoints;
    private Point? startPoint;

    public void SetPage(byte[] png, JsonObject annotations, int index)
    {
        using var stream = new MemoryStream(png);
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.StreamSource = stream;
        bitmap.EndInit();
        bitmap.Freeze();
        image = bitmap;
        Document = annotations;
        pageIndex = index;
        InvalidateVisual();
    }

    public void AddText(double x, double y, string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        Objects().Add(new JsonObject {
            ["id"] = $"text-{Guid.NewGuid()}",
            ["type"] = "text",
            ["pageIndex"] = pageIndex,
            ["text"] = value,
            ["bbox"] = new JsonObject {
                ["x"] = x, ["y"] = y,
                ["width"] = Math.Min(0.45, Math.Max(0.12, value.Length * 0.018)),
                ["height"] = 0.08
            },
            ["metadata"] = new JsonObject { ["color"] = "#111111", ["fontSize"] = "16" }
        });
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        drawing.DrawRectangle(Brushes.LightGray, null, new Rect(RenderSize));
        if (image is null) return;
        var scale = Math.Min(ActualWidth / image.PixelWidth, ActualHeight / image.PixelHeight);
        var width = image.PixelWidth * scale;
        var height = image.PixelHeight * scale;
        pageRect = new Rect((ActualWidth - width) / 2, (ActualHeight - height) / 2, width, height);
        drawing.DrawImage(image, pageRect);
        drawing.PushClip(new RectangleGeometry(pageRect));
        DrawStrokes(drawing);
        DrawObjects(drawing);
        drawing.Pop();
    }

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        var point = Normalize(e.GetPosition(this));
        if (point is null) return;
        CaptureMouse();
        if (Tool == AnnotationTool.Pen)
            activePoints = new JsonArray(PointNode(point.Value.X, point.Value.Y));
        else if (Tool == AnnotationTool.Rectangle)
            startPoint = point;
        e.Handled = Tool != AnnotationTool.Pan;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (Tool != AnnotationTool.Pen || activePoints is null || e.LeftButton != MouseButtonState.Pressed) return;
        var point = Normalize(e.GetPosition(this));
        if (point is null) return;
        activePoints.Add(PointNode(point.Value.X, point.Value.Y));
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        var point = Normalize(e.GetPosition(this));
        if (point is not null && Tool == AnnotationTool.Pen && activePoints is { Count: > 1 })
        {
            Strokes().Add(new JsonObject {
                ["id"] = $"stroke-{Guid.NewGuid()}",
                ["tool"] = "pen", ["color"] = "#1769aa", ["width"] = 2.5,
                ["opacity"] = 1.0, ["points"] = activePoints
            });
        }
        else if (point is not null && Tool == AnnotationTool.Rectangle && startPoint is { } start)
        {
            Objects().Add(new JsonObject {
                ["id"] = $"rectangle-{Guid.NewGuid()}",
                ["type"] = "rectangle", ["pageIndex"] = pageIndex,
                ["bbox"] = new JsonObject {
                    ["x"] = Math.Min(start.X, point.Value.X),
                    ["y"] = Math.Min(start.Y, point.Value.Y),
                    ["width"] = Math.Max(0.005, Math.Abs(point.Value.X - start.X)),
                    ["height"] = Math.Max(0.005, Math.Abs(point.Value.Y - start.Y))
                },
                ["metadata"] = new JsonObject { ["color"] = "#d32f2f", ["lineWidth"] = "2" }
            });
        }
        else if (point is not null && Tool == AnnotationTool.Text)
            TextRequested?.Invoke(point.Value.X, point.Value.Y);
        activePoints = null;
        startPoint = null;
        ReleaseMouseCapture();
        InvalidateVisual();
        e.Handled = Tool != AnnotationTool.Pan;
    }

    private void DrawStrokes(DrawingContext drawing)
    {
        if (Page()["inkStrokes"] is not JsonArray strokes) return;
        foreach (var node in strokes.OfType<JsonObject>())
        {
            if (node["points"] is not JsonArray points || points.Count < 2) continue;
            var geometry = new StreamGeometry();
            using (var context = geometry.Open())
            {
                var first = PointValue(points[0]!.AsObject());
                context.BeginFigure(ToView(first), false, false);
                context.PolyLineTo(points.Skip(1).Select(value => ToView(PointValue(value!.AsObject()))).ToList(), true, false);
            }
            geometry.Freeze();
            drawing.DrawGeometry(null, new Pen(ColorBrush(node["color"]?.GetValue<string>() ?? "#1769aa"), node["width"]?.GetValue<double>() ?? 2.5) {
                StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round
            }, geometry);
        }
        if (activePoints is { Count: > 1 })
        {
            var geometry = new StreamGeometry();
            using var context = geometry.Open();
            context.BeginFigure(ToView(PointValue(activePoints[0]!.AsObject())), false, false);
            context.PolyLineTo(activePoints.Skip(1).Select(value => ToView(PointValue(value!.AsObject()))).ToList(), true, false);
            drawing.DrawGeometry(null, new Pen(Brushes.SteelBlue, 2.5), geometry);
        }
    }

    private void DrawObjects(DrawingContext drawing)
    {
        if (Page()["objects"] is not JsonArray objects) return;
        foreach (var item in objects.OfType<JsonObject>())
        {
            if (item["bbox"] is not JsonObject box) continue;
            var rect = new Rect(
                X(box["x"]?.GetValue<double>() ?? 0),
                Y(box["y"]?.GetValue<double>() ?? 0),
                (box["width"]?.GetValue<double>() ?? 0) * pageRect.Width,
                (box["height"]?.GetValue<double>() ?? 0) * pageRect.Height);
            var color = item["metadata"]?["color"]?.GetValue<string>() ?? "#d32f2f";
            if (item["type"]?.GetValue<string>() == "text")
            {
                var text = new FormattedText(item["text"]?.GetValue<string>() ?? "", System.Globalization.CultureInfo.CurrentCulture,
                    FlowDirection.LeftToRight, new Typeface("Segoe UI"), 16, ColorBrush(color), 1.0);
                drawing.DrawText(text, rect.TopLeft);
            }
            else drawing.DrawRectangle(null, new Pen(ColorBrush(color), 2), rect);
        }
    }

    private JsonObject Page()
    {
        var pages = Document["pages"] as JsonArray ?? new JsonArray();
        Document["pages"] = pages;
        foreach (var value in pages.OfType<JsonObject>())
            if (value["pageIndex"]?.GetValue<int>() == pageIndex) return value;
        var page = new JsonObject { ["pageIndex"] = pageIndex, ["inkStrokes"] = new JsonArray(), ["objects"] = new JsonArray() };
        pages.Add(page);
        return page;
    }
    private JsonArray Strokes() => Page()["inkStrokes"] as JsonArray ?? SetArray(Page(), "inkStrokes");
    private JsonArray Objects() => Page()["objects"] as JsonArray ?? SetArray(Page(), "objects");
    private static JsonArray SetArray(JsonObject target, string name) { var value = new JsonArray(); target[name] = value; return value; }
    private Point? Normalize(Point point) => pageRect.Contains(point)
        ? new Point((point.X - pageRect.X) / pageRect.Width, (point.Y - pageRect.Y) / pageRect.Height) : null;
    private Point ToView(Point point) => new(X(point.X), Y(point.Y));
    private double X(double value) => pageRect.X + value * pageRect.Width;
    private double Y(double value) => pageRect.Y + value * pageRect.Height;
    private static JsonObject PointNode(double x, double y) => new() { ["x"] = x, ["y"] = y, ["pressure"] = 1.0 };
    private static Point PointValue(JsonObject value) => new(value["x"]?.GetValue<double>() ?? 0, value["y"]?.GetValue<double>() ?? 0);
    private static Brush ColorBrush(string value) {
        try { return new SolidColorBrush((Color)ColorConverter.ConvertFromString(value)); }
        catch { return Brushes.Black; }
    }
}
