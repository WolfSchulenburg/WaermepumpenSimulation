unit uBericht;

{$mode objfpc}{$H+}

// ================================================================
// Grafischer HTML-Bericht
//
// Schreibt eine einzelne, vollstaendig eigenstaendige HTML-Datei
// (kein Internetzugriff/keine externen Bibliotheken noetig - reines
// HTML5-Canvas mit selbst geschriebenem JavaScript), die je Szenario
// zwei Diagramme sowie eine Monatstabelle enthaelt:
//
//   - "Heizlast vs. WP-Maxleistung" ueber der Aussentemperatur, um
//     visuell zu sehen, ab welcher Aussentemperatur der Heizstab
//     einspringen muss (Bivalenzpunkt).
//   - Streudiagramm aller 8760 Stundenwerte (Aussentemperatur/COP),
//     farbcodiert nach Effizienz - angelehnt an die "Jahressimulation"
//     im Akkudoktor-Waermepumpenrechner (tools.akkudoktor.net/wp).
// ================================================================

interface

uses
  SysUtils, uWPTypes, uSimulation;

procedure GenerateHTMLReport(const Ergebnisse: array of TJahresErgebnis;
  const Szenarien: array of TSzenarioKonfiguration; const FileName: string);

implementation

// JavaScript verlangt einen Punkt als Dezimaltrennzeichen, unabhaengig
// vom sonst in diesem Programm fuer CSV verwendeten Komma.
function JSNum(const Value: Double): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FormatFloat('0.00', Value, FS);
end;

function HTMLEscape(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

procedure WriteChartJS(var F: TextFile);
begin
  Writeln(F, 'function computeBounds(seriesArr) {');
  Writeln(F, '  var xmin = Infinity, xmax = -Infinity, ymin = Infinity, ymax = -Infinity;');
  Writeln(F, '  var s, i, pts;');
  Writeln(F, '  for (s = 0; s < seriesArr.length; s++) {');
  Writeln(F, '    pts = seriesArr[s].points;');
  Writeln(F, '    for (i = 0; i < pts.length; i++) {');
  Writeln(F, '      if (pts[i][0] < xmin) xmin = pts[i][0];');
  Writeln(F, '      if (pts[i][0] > xmax) xmax = pts[i][0];');
  Writeln(F, '      if (pts[i][1] < ymin) ymin = pts[i][1];');
  Writeln(F, '      if (pts[i][1] > ymax) ymax = pts[i][1];');
  Writeln(F, '    }');
  Writeln(F, '  }');
  Writeln(F, '  if (xmin === xmax) { xmin -= 1; xmax += 1; }');
  Writeln(F, '  if (ymin === ymax) { ymin -= 1; ymax += 1; }');
  Writeln(F, '  var xpad = (xmax - xmin) * 0.05;');
  Writeln(F, '  var ypad = (ymax - ymin) * 0.08;');
  Writeln(F, '  return { xmin: xmin - xpad, xmax: xmax + xpad, ymin: ymin - ypad, ymax: ymax + ypad };');
  Writeln(F, '}');
  Writeln(F, 'function toPixel(x, y, bounds, margin, plotW, plotH) {');
  Writeln(F, '  var px = margin.left + (x - bounds.xmin) / (bounds.xmax - bounds.xmin) * plotW;');
  Writeln(F, '  var py = margin.top + plotH - (y - bounds.ymin) / (bounds.ymax - bounds.ymin) * plotH;');
  Writeln(F, '  return [px, py];');
  Writeln(F, '}');
  Writeln(F, 'function drawAxes(ctx, w, h, margin, bounds, xLabel, yLabel) {');
  Writeln(F, '  var plotW = w - margin.left - margin.right;');
  Writeln(F, '  var plotH = h - margin.top - margin.bottom;');
  Writeln(F, '  var nTicksX = 6, nTicksY = 5;');
  Writeln(F, '  var i, x, y, val;');
  Writeln(F, '  ctx.font = "11px sans-serif";');
  Writeln(F, '  ctx.lineWidth = 1;');
  Writeln(F, '  for (i = 0; i <= nTicksY; i++) {');
  Writeln(F, '    val = bounds.ymin + (bounds.ymax - bounds.ymin) * i / nTicksY;');
  Writeln(F, '    y = margin.top + plotH - (plotH * i / nTicksY);');
  Writeln(F, '    ctx.strokeStyle = "#eee";');
  Writeln(F, '    ctx.beginPath();');
  Writeln(F, '    ctx.moveTo(margin.left, y);');
  Writeln(F, '    ctx.lineTo(margin.left + plotW, y);');
  Writeln(F, '    ctx.stroke();');
  Writeln(F, '    ctx.fillStyle = "#333";');
  Writeln(F, '    ctx.textAlign = "right";');
  Writeln(F, '    ctx.textBaseline = "middle";');
  Writeln(F, '    ctx.fillText(val.toFixed(1), margin.left - 6, y);');
  Writeln(F, '  }');
  Writeln(F, '  for (i = 0; i <= nTicksX; i++) {');
  Writeln(F, '    val = bounds.xmin + (bounds.xmax - bounds.xmin) * i / nTicksX;');
  Writeln(F, '    x = margin.left + (plotW * i / nTicksX);');
  Writeln(F, '    ctx.strokeStyle = "#eee";');
  Writeln(F, '    ctx.beginPath();');
  Writeln(F, '    ctx.moveTo(x, margin.top);');
  Writeln(F, '    ctx.lineTo(x, margin.top + plotH);');
  Writeln(F, '    ctx.stroke();');
  Writeln(F, '    ctx.fillStyle = "#333";');
  Writeln(F, '    ctx.textAlign = "center";');
  Writeln(F, '    ctx.textBaseline = "top";');
  Writeln(F, '    ctx.fillText(val.toFixed(0), x, margin.top + plotH + 6);');
  Writeln(F, '  }');
  Writeln(F, '  ctx.strokeStyle = "#333";');
  Writeln(F, '  ctx.beginPath();');
  Writeln(F, '  ctx.moveTo(margin.left, margin.top);');
  Writeln(F, '  ctx.lineTo(margin.left, margin.top + plotH);');
  Writeln(F, '  ctx.lineTo(margin.left + plotW, margin.top + plotH);');
  Writeln(F, '  ctx.stroke();');
  Writeln(F, '  ctx.fillStyle = "#333";');
  Writeln(F, '  ctx.textAlign = "center";');
  Writeln(F, '  ctx.textBaseline = "alphabetic";');
  Writeln(F, '  ctx.fillText(xLabel, margin.left + plotW / 2, margin.top + plotH + 24);');
  Writeln(F, '  ctx.save();');
  Writeln(F, '  ctx.translate(14, margin.top + plotH / 2);');
  Writeln(F, '  ctx.rotate(-Math.PI / 2);');
  Writeln(F, '  ctx.textAlign = "center";');
  Writeln(F, '  ctx.fillText(yLabel, 0, 0);');
  Writeln(F, '  ctx.restore();');
  Writeln(F, '}');
  Writeln(F, 'function drawLineChart(canvasId, seriesArr, xLabel, yLabel) {');
  Writeln(F, '  var canvas = document.getElementById(canvasId);');
  Writeln(F, '  var ctx = canvas.getContext("2d");');
  Writeln(F, '  var w = canvas.width, h = canvas.height;');
  Writeln(F, '  var margin = { left: 55, right: 15, top: 15, bottom: 45 };');
  Writeln(F, '  var plotW = w - margin.left - margin.right;');
  Writeln(F, '  var plotH = h - margin.top - margin.bottom;');
  Writeln(F, '  var bounds, s, pts, i, p, s2;');
  Writeln(F, '  ctx.clearRect(0, 0, w, h);');
  Writeln(F, '  bounds = computeBounds(seriesArr);');
  Writeln(F, '  drawAxes(ctx, w, h, margin, bounds, xLabel, yLabel);');
  Writeln(F, '  for (s = 0; s < seriesArr.length; s++) {');
  Writeln(F, '    pts = seriesArr[s].points;');
  Writeln(F, '    ctx.strokeStyle = seriesArr[s].color;');
  Writeln(F, '    ctx.lineWidth = 2;');
  Writeln(F, '    ctx.beginPath();');
  Writeln(F, '    for (i = 0; i < pts.length; i++) {');
  Writeln(F, '      p = toPixel(pts[i][0], pts[i][1], bounds, margin, plotW, plotH);');
  Writeln(F, '      if (i === 0) { ctx.moveTo(p[0], p[1]); } else { ctx.lineTo(p[0], p[1]); }');
  Writeln(F, '    }');
  Writeln(F, '    ctx.stroke();');
  Writeln(F, '  }');
  Writeln(F, '  var lx = margin.left + 10, ly = margin.top + 10;');
  Writeln(F, '  ctx.font = "12px sans-serif";');
  Writeln(F, '  for (s2 = 0; s2 < seriesArr.length; s2++) {');
  Writeln(F, '    ctx.fillStyle = seriesArr[s2].color;');
  Writeln(F, '    ctx.fillRect(lx, ly + s2 * 18, 14, 4);');
  Writeln(F, '    ctx.fillStyle = "#333";');
  Writeln(F, '    ctx.textAlign = "left";');
  Writeln(F, '    ctx.textBaseline = "middle";');
  Writeln(F, '    ctx.fillText(seriesArr[s2].label, lx + 20, ly + s2 * 18 + 2);');
  Writeln(F, '  }');
  Writeln(F, '}');
  Writeln(F, 'function copColor(cop) {');
  Writeln(F, '  if (cop >= 4.5) return "#2e7d32";');
  Writeln(F, '  if (cop >= 3.0) return "#f9a825";');
  Writeln(F, '  if (cop > 0) return "#c62828";');
  Writeln(F, '  return "#999999";');
  Writeln(F, '}');
  Writeln(F, 'function drawScatter(canvasId, points, xLabel, yLabel) {');
  Writeln(F, '  var canvas = document.getElementById(canvasId);');
  Writeln(F, '  var ctx = canvas.getContext("2d");');
  Writeln(F, '  var w = canvas.width, h = canvas.height;');
  Writeln(F, '  var margin = { left: 55, right: 15, top: 15, bottom: 45 };');
  Writeln(F, '  var plotW = w - margin.left - margin.right;');
  Writeln(F, '  var plotH = h - margin.top - margin.bottom;');
  Writeln(F, '  var bounds, i, p, k, legendItems, lx, ly;');
  Writeln(F, '  ctx.clearRect(0, 0, w, h);');
  Writeln(F, '  bounds = computeBounds([{ points: points }]);');
  Writeln(F, '  drawAxes(ctx, w, h, margin, bounds, xLabel, yLabel);');
  Writeln(F, '  for (i = 0; i < points.length; i++) {');
  Writeln(F, '    p = toPixel(points[i][0], points[i][1], bounds, margin, plotW, plotH);');
  Writeln(F, '    ctx.fillStyle = copColor(points[i][1]);');
  Writeln(F, '    ctx.fillRect(p[0] - 1, p[1] - 1, 2, 2);');
  Writeln(F, '  }');
  Writeln(F, '  legendItems = [["COP >= 4.5", "#2e7d32"], ["3.0 - 4.5", "#f9a825"], ["< 3.0", "#c62828"]];');
  Writeln(F, '  lx = margin.left + 10; ly = margin.top + 10;');
  Writeln(F, '  ctx.font = "12px sans-serif";');
  Writeln(F, '  for (k = 0; k < legendItems.length; k++) {');
  Writeln(F, '    ctx.fillStyle = legendItems[k][1];');
  Writeln(F, '    ctx.fillRect(lx, ly + k * 18, 10, 10);');
  Writeln(F, '    ctx.fillStyle = "#333";');
  Writeln(F, '    ctx.textAlign = "left";');
  Writeln(F, '    ctx.textBaseline = "middle";');
  Writeln(F, '    ctx.fillText(legendItems[k][0], lx + 16, ly + k * 18 + 5);');
  Writeln(F, '  }');
  Writeln(F, '}');
end;

procedure GenerateHTMLReport(const Ergebnisse: array of TJahresErgebnis;
  const Szenarien: array of TSzenarioKonfiguration; const FileName: string);
const
  MonatsNamen: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'Mai',
    'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez');
var
  F: TextFile;
  I, J, M: Integer;
  ScenID: string;
  T, Load, Capacity, FlowT, MonatJAZ: Double;
  ErsteZeile: Boolean;
begin
  AssignFile(F, FileName);
  Rewrite(F);
  try
    Writeln(F, '<!DOCTYPE html>');
    Writeln(F, '<html lang="de"><head><meta charset="UTF-8">');
    Writeln(F, '<title>Waermepumpen-Simulation - Bericht</title>');
    Writeln(F, '<style>');
    Writeln(F, 'body{font-family:sans-serif;margin:24px;background:#fafafa;color:#222;}');
    Writeln(F, 'h1{font-size:22px;}');
    Writeln(F, 'h2{font-size:18px;margin-top:40px;border-bottom:2px solid #ddd;padding-bottom:4px;}');
    Writeln(F, 'table{border-collapse:collapse;margin:12px 0;}');
    Writeln(F, 'th,td{border:1px solid #ccc;padding:5px 10px;text-align:right;font-size:13px;}');
    Writeln(F, 'th{background:#eee;}');
    Writeln(F, 'td:first-child,th:first-child{text-align:left;}');
    Writeln(F, '.kennzahlen{display:flex;gap:16px;flex-wrap:wrap;margin:12px 0;}');
    Writeln(F, '.kennzahl{background:#fff;border:1px solid #ddd;border-radius:6px;padding:10px 16px;min-width:140px;}');
    Writeln(F, '.kennzahl .wert{font-size:20px;font-weight:bold;}');
    Writeln(F, '.kennzahl .label{font-size:12px;color:#666;}');
    Writeln(F, 'canvas{background:#fff;border:1px solid #ddd;border-radius:6px;margin:8px 12px 8px 0;}');
    Writeln(F, '.charts{display:flex;flex-wrap:wrap;}');
    Writeln(F, '.hinweis{color:#a15c00;font-size:13px;background:#fff8e6;border:1px solid #ffe1a6;padding:8px 12px;border-radius:6px;max-width:800px;}');
    Writeln(F, '</style>');
    Writeln(F, '<script>');
    WriteChartJS(F);
    Writeln(F, '</script>');
    Writeln(F, '</head><body>');

    Writeln(F, '<h1>Waermepumpen-Simulation - Bericht</h1>');
    Writeln(F,
      Format(
        '<p class="hinweis">Alle COP-/Leistungswerte sowie die ' +
        'Wirtschaftlichkeits-Annahmen (Strompreis %s EUR/kWh, ' +
        'Brennstoffpreise/Wirkungsgrad der bisherigen Heizung) sind, ' +
        'soweit nicht aus einer echten TRY-Wetterdatei bzw. einem ' +
        'echten Datenblatt uebernommen, Platzhalter - siehe ' +
        'Kommentare im Quelltext bzw. die Konfigurationsdatei.</p>',
        [JSNum(StromPreis)]));

    // -- Uebersichtstabelle ---------------------------------------
    Writeln(F, '<h2>Szenarien im Vergleich</h2>');
    Writeln(F, '<table><tr><th>Szenario</th><th>JAZ</th>' +
      '<th>Taktrisiko</th><th>Abtau-Risiko</th><th>Kosten bisher</th>' +
      '<th>Kosten WP</th><th>Ersparnis</th></tr>');
    for I := 0 to High(Ergebnisse) do
      Writeln(F,
        Format(
          '<tr><td>%s</td><td>%.2f</td><td>%.1f %%</td>' +
          '<td>%d h</td><td>%.0f EUR</td><td>%.0f EUR</td>' +
          '<td>%.0f EUR</td></tr>',
          [HTMLEscape(Ergebnisse[I].ScenarioName), Ergebnisse[I].JAZ,
           Ergebnisse[I].TaktRisikoAnteil,
           Ergebnisse[I].AbtauRisikoStunden, Ergebnisse[I].KostenAlt,
           Ergebnisse[I].KostenNeu, Ergebnisse[I].Ersparnis]));
    Writeln(F, '</table>');

    // -- Details je Szenario ---------------------------------------
    for I := 0 to High(Ergebnisse) do
    begin
      ScenID := IntToStr(I);

      Writeln(F, Format('<h2>%s</h2>',
        [HTMLEscape(Ergebnisse[I].ScenarioName)]));

      Writeln(F, '<div class="kennzahlen">');
      Writeln(F, Format(
        '<div class="kennzahl"><div class="wert">%.2f</div>' +
        '<div class="label">Jahresarbeitszahl</div></div>',
        [Ergebnisse[I].JAZ]));
      Writeln(F, Format(
        '<div class="kennzahl"><div class="wert">%.0f kWh</div>' +
        '<div class="label">Stromverbrauch/Jahr</div></div>',
        [Ergebnisse[I].TotalElectric]));
      Writeln(F, Format(
        '<div class="kennzahl"><div class="wert">%.1f %%</div>' +
        '<div class="label">Taktrisiko (Kurzzyklen)</div></div>',
        [Ergebnisse[I].TaktRisikoAnteil]));
      Writeln(F, Format(
        '<div class="kennzahl"><div class="wert">%d h</div>' +
        '<div class="label">Abtau-Risiko-Stunden</div></div>',
        [Ergebnisse[I].AbtauRisikoStunden]));
      Writeln(F, Format(
        '<div class="kennzahl"><div class="wert">%.0f EUR</div>' +
        '<div class="label">Ersparnis ggue. bisheriger Heizung</div></div>',
        [Ergebnisse[I].Ersparnis]));
      if Szenarien[I].WP.AnzahlEinheiten > 1 then
      begin
        Writeln(F, Format(
          '<div class="kennzahl"><div class="wert">%d von %d</div>' +
          '<div class="label">Max. gleichzeitig aktive Einheiten</div></div>',
          [Ergebnisse[I].MaxAktiveEinheiten, Szenarien[I].WP.AnzahlEinheiten]));
        if Ergebnisse[I].ActiveHours > 0 then
          Writeln(F, Format(
            '<div class="kennzahl"><div class="wert">%.2f</div>' +
            '<div class="label">Mittlere aktive Einheiten (bei Betrieb)</div></div>',
            [Ergebnisse[I].SummeAktiveEinheiten / Ergebnisse[I].ActiveHours]));
      end;
      Writeln(F, '</div>');

      Writeln(F, '<div class="charts">');
      Writeln(F, Format(
        '<div><b>Heizlast vs. WP-Maxleistung</b><br>' +
        '<canvas id="kennlinie_%s" width="640" height="360"></canvas></div>',
        [ScenID]));
      Writeln(F, Format(
        '<div><b>Stundenwerte: Aussentemperatur / COP</b><br>' +
        '<canvas id="scatter_%s" width="640" height="360"></canvas></div>',
        [ScenID]));
      Writeln(F, '</div>');

      // -- Monatstabelle ---------------------------------------------
      Writeln(F, '<table><tr><th>Monat</th><th>Heizwaerme (kWh)</th>' +
        '<th>TWW (kWh)</th><th>Strom (kWh)</th><th>JAZ</th>' +
        '<th>Heizstab (kWh)</th><th>Takt-Std.</th><th>Abtau-Std.</th></tr>');
      for M := 1 to 12 do
      begin
        if Ergebnisse[I].Monate[M].Electric > 0 then
          MonatJAZ :=
            (Ergebnisse[I].Monate[M].Heat + Ergebnisse[I].Monate[M].TWW) /
            Ergebnisse[I].Monate[M].Electric
        else
          MonatJAZ := 0;

        Writeln(F,
          Format(
            '<tr><td>%s</td><td>%.0f</td><td>%.0f</td><td>%.0f</td>' +
            '<td>%.2f</td><td>%.0f</td><td>%d</td><td>%d</td></tr>',
            [MonatsNamen[M], Ergebnisse[I].Monate[M].Heat,
             Ergebnisse[I].Monate[M].TWW, Ergebnisse[I].Monate[M].Electric,
             MonatJAZ, Ergebnisse[I].Monate[M].Heater,
             Ergebnisse[I].Monate[M].TaktStunden,
             Ergebnisse[I].Monate[M].AbtauStunden]));
      end;
      Writeln(F, '</table>');
    end;

    Writeln(F, '<script>');

    // -- Kennlinie und Streudiagramm je Szenario --------------------
    for I := 0 to High(Ergebnisse) do
    begin
      ScenID := IntToStr(I);

      Write(F, Format(
        'var kennlinie_data_%s = [{label:"Heizlast (Raumheizung)", ' +
        'color:"#7b1fa2", points:[', [ScenID]));
      T := -20.0;
      ErsteZeile := True;
      while T <= 20.0001 do
      begin
        if not ErsteZeile then Write(F, ',');
        ErsteZeile := False;
        Load := Szenarien[I].Gebaeude.HeatingDemand(T);
        Write(F, '[', JSNum(T), ',', JSNum(Load), ']');
        T := T + 0.5;
      end;
      Write(F, ']},{label:"WP-Maxleistung", color:"#d32f2f", points:[');
      T := -20.0;
      ErsteZeile := True;
      while T <= 20.0001 do
      begin
        if not ErsteZeile then Write(F, ',');
        ErsteZeile := False;
        FlowT := Szenarien[I].WP.FlowTemperature(T);
        Capacity := Szenarien[I].WP.MaxHeatingPower(T, FlowT);
        Write(F, '[', JSNum(T), ',', JSNum(Capacity), ']');
        T := T + 0.5;
      end;
      Writeln(F, ']}];');
      Writeln(F, Format(
        'drawLineChart("kennlinie_%s", kennlinie_data_%s, ' +
        '"Aussentemperatur (C)", "Leistung (kW)");', [ScenID, ScenID]));

      Write(F, Format('var scatter_data_%s = [', [ScenID]));
      for J := 0 to High(Ergebnisse[I].StundenAussen) do
      begin
        if J > 0 then Write(F, ',');
        Write(F, '[', JSNum(Ergebnisse[I].StundenAussen[J]), ',',
          JSNum(Ergebnisse[I].StundenCOP[J]), ']');
      end;
      Writeln(F, '];');
      Writeln(F, Format(
        'drawScatter("scatter_%s", scatter_data_%s, ' +
        '"Aussentemperatur (C)", "COP");', [ScenID, ScenID]));
    end;

    Writeln(F, '</script>');
    Writeln(F, '</body></html>');
  finally
    CloseFile(F);
  end;
end;

end.
