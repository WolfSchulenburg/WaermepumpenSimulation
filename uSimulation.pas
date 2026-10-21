unit uSimulation;

{$mode objfpc}{$H+}

// ================================================================
// Der eigentliche Simulationskern: ein Jahr Stundenwerte fuer ein
// Szenario (Waermeerzeuger + Gebaeude) durchrechnen und als
// TJahresErgebnis zusammenfassen, inkl. stuendlichem CSV-Export.
//
// RunSimulation kennt nur die abstrakte Schnittstelle TWaermeErzeuger
// (siehe uWPTypes) - ob dahinter eine einzelne TWaermepumpe oder eine
// TWaermepumpenKaskade steckt, macht hier keinen Unterschied.
// ================================================================

interface

uses
  SysUtils, uWPTypes;

const
  // Dauer-Standby-Verbrauch der Waermepumpensteuerung/-anlage, faellt
  // unabhaengig vom Betrieb jede Stunde an (vgl. Akkudoktor-Rechner:
  // "35W Dauer-Standby").
  StandbyLeistung = 0.035;  // kW

  // Vereinfachter Mehrverbrauch in Takt-Risiko-Stunden (Anforderung
  // unter der Mindestleistung -> haeufiges Ein-/Ausschalten statt
  // stabilem Betrieb). Akkudoktor nennt bis zu 25 % Anlaufverluste bei
  // intensivem Takten; wir setzen konservativ 15 % an.
  StartupVerlustFaktor = 1.15;

  TageProMonat: array[1..12] of Integer =
    (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);

  // PLATZHALTER - an den tatsaechlichen Stromtarif anpassen.
  StromPreis = 0.30;  // EUR/kWh

type
  // Monatswerte (Index 1..12), fuer die Monatsbilanz-Tabelle im Bericht.
  TMonatsWerte = record
    Heat, TWW, Electric, Heater: Double;  // kWh
    TaktStunden, AbtauStunden: Integer;
  end;

  // Ergebnis eines Simulationslaufs (ein Jahr, ein Szenario)
  TJahresErgebnis = record
    ScenarioName: string;
    TotalHeat: Double;      // kWh Raumwaerme
    TotalTWW: Double;       // kWh Trinkwarmwasser
    TotalElectric: Double;  // kWh Strom gesamt
    TotalHeater: Double;    // kWh Heizstab-Anteil
    JAZ: Double;

    ActiveHours: Integer;        // Stunden mit WP-Anforderung > 0
    TaktRisikoStunden: Integer;  // davon: Anforderung < Mindestleistung
    TaktRisikoAnteil: Double;    // % von ActiveHours
    AbtauRisikoStunden: Integer; // Stunden mit erhoehtem Vereisungsrisiko

    // Nur bei einer Kaskade interessant (bei einer einzelnen WP immer
    // 0 oder 1): wie viele der Einheiten je Stunde tatsaechlich liefen.
    SummeAktiveEinheiten: Int64;  // Summe ueber alle Betriebsstunden
    MaxAktiveEinheiten: Integer;  // Spitzenwert (max. gleichzeitig aktiv)

    KostenAlt: Double;   // EUR/Jahr, hypothetisch mit bisheriger Heizung
    KostenNeu: Double;   // EUR/Jahr, mit der Waermepumpe
    Ersparnis: Double;   // EUR/Jahr, KostenAlt - KostenNeu

    Monate: array[1..12] of TMonatsWerte;

    // Stuendliche Aussentemperatur/COP-Paare, fuer das Streudiagramm
    // im HTML-Bericht (siehe uBericht.GenerateHTMLReport).
    StundenAussen: TDoubleArray;
    StundenCOP: TDoubleArray;
  end;

// Ordnet einen 0-basierten Stundenindex (0..8759) einem Kalendermonat
// zu (1..12), unter der Annahme eines Nicht-Schaltjahres beginnend am
// 1. Januar - fuer synthetische/einfache CSV-Wetterdaten ist das eine
// Naeherung, fuer TRY-Daten passt es (TRY-Jahre sind Nicht-Schaltjahre).
function MonatVonStunde(Hour: Integer): Integer;

function RunSimulation(WP: TWaermeErzeuger; Building: TGebaeude;
  const Temps: TDoubleArray; const CSVFileName: string;
  ShowConsoleDetails: Boolean): TJahresErgebnis;

implementation

function MonatVonStunde(Hour: Integer): Integer;
var
  Tag, M, KumTage: Integer;
begin
  Tag := Hour div 24;
  KumTage := 0;
  for M := 1 to 12 do
  begin
    KumTage := KumTage + TageProMonat[M];
    if Tag < KumTage then
      Exit(M);
  end;
  Result := 12;
end;

function RunSimulation(WP: TWaermeErzeuger; Building: TGebaeude;
  const Temps: TDoubleArray; const CSVFileName: string;
  ShowConsoleDetails: Boolean): TJahresErgebnis;
var
  CSVFile: TextFile;
  CSVFormat: TFormatSettings;

  Hour, Monat: Integer;
  OutsideTemp, FlowTemp: Double;

  HeatDemand, TWWDemand: Double;
  MaxWPHeat, MinWPHeat, WPHeatTotal: Double;
  WPHeatSpace, WPHeatTWW: Double;
  RemainingCapacity: Double;
  HeaterHeat: Double;

  CurrentCOP: Double;
  ElectricSpace, ElectricTWW, ElectricPower: Double;
  IstTaktRisiko, IstAbtauRisiko: Boolean;
  AktiveWPs: Integer;
begin
  CSVFormat := DefaultFormatSettings;
  CSVFormat.DecimalSeparator := ',';

  Result.ScenarioName := WP.Name + ' / ' + Building.Name;
  Result.TotalHeat := 0.0;
  Result.TotalTWW := 0.0;
  Result.TotalElectric := 0.0;
  Result.TotalHeater := 0.0;
  Result.ActiveHours := 0;
  Result.TaktRisikoStunden := 0;
  Result.AbtauRisikoStunden := 0;
  Result.SummeAktiveEinheiten := 0;
  Result.MaxAktiveEinheiten := 0;

  for Monat := 1 to 12 do
  begin
    Result.Monate[Monat].Heat := 0;
    Result.Monate[Monat].TWW := 0;
    Result.Monate[Monat].Electric := 0;
    Result.Monate[Monat].Heater := 0;
    Result.Monate[Monat].TaktStunden := 0;
    Result.Monate[Monat].AbtauStunden := 0;
  end;

  SetLength(Result.StundenAussen, Length(Temps));
  SetLength(Result.StundenCOP, Length(Temps));

  AssignFile(CSVFile, CSVFileName);
  Rewrite(CSVFile);
  try
    Writeln(CSVFile,
      'Stunde;Aussentemp_C;Vorlauf_C;Heizbedarf_kW;TWW_kW;' +
      'WP_Heizung_kW;WP_TWW_kW;Heizstab_kW;COP;Strom_kW;' +
      'Taktrisiko;AbtauRisiko;AktiveEinheiten');

    if ShowConsoleDetails then
    begin
      Writeln('---------------------------------------------');
      Writeln(' Szenario: ' + Result.ScenarioName);
      Writeln('---------------------------------------------');
      Writeln;
    end;

    for Hour := 0 to High(Temps) do
    begin
      OutsideTemp := Temps[Hour];
      Monat := MonatVonStunde(Hour);

      // -- Bedarf -------------------------------------------------
      HeatDemand := Building.HeatingDemand(OutsideTemp);
      TWWDemand := Building.TWWDemand(Hour);

      // -- Waermepumpe ---------------------------------------------
      FlowTemp := WP.FlowTemperature(OutsideTemp);
      MaxWPHeat := WP.MaxHeatingPower(OutsideTemp, FlowTemp);

      // Raumheizung hat Vorrang, TWW nutzt die restliche Kapazitaet
      if HeatDemand <= MaxWPHeat then
        WPHeatSpace := HeatDemand
      else
        WPHeatSpace := MaxWPHeat;

      RemainingCapacity := MaxWPHeat - WPHeatSpace;

      if TWWDemand <= RemainingCapacity then
        WPHeatTWW := TWWDemand
      else
        WPHeatTWW := RemainingCapacity;

      // Rest wird durch den Heizstab geliefert (COP = 1)
      HeaterHeat :=
        (HeatDemand - WPHeatSpace) + (TWWDemand - WPHeatTWW);

      if HeaterHeat < 0 then
        HeaterHeat := 0;

      // -- Taktrisiko: geforderte WP-Leistung liegt unter der
      // Mindestleistung, die WP kann also nicht mehr stabil
      // modulieren und muss takten (ein-/ausschalten). --------------
      WPHeatTotal := WPHeatSpace + WPHeatTWW;
      IstTaktRisiko := False;
      AktiveWPs := WP.AktiveEinheiten(OutsideTemp, FlowTemp, WPHeatTotal);

      if WPHeatTotal > 0 then
      begin
        Inc(Result.ActiveHours);
        Result.SummeAktiveEinheiten := Result.SummeAktiveEinheiten + AktiveWPs;
        if AktiveWPs > Result.MaxAktiveEinheiten then
          Result.MaxAktiveEinheiten := AktiveWPs;

        MinWPHeat := WP.MinHeatingPower(OutsideTemp, FlowTemp);
        if WPHeatTotal < MinWPHeat then
        begin
          IstTaktRisiko := True;
          Inc(Result.TaktRisikoStunden);
          Inc(Result.Monate[Monat].TaktStunden);
        end;
      end;

      // -- Abtau-Risiko: Aussentemperatur im vereisungsgefaehrdeten
      // Bereich (siehe DefrostFactor). Ohne Feuchtedaten (nur bei
      // TRY-Import verfuegbar, hier aber nicht durchgereicht) eine
      // konservative Abschaetzung rein ueber die Temperatur. --------
      IstAbtauRisiko := WP.AbtauRisikoBedingung(OutsideTemp);
      if IstAbtauRisiko then
      begin
        Inc(Result.AbtauRisikoStunden);
        Inc(Result.Monate[Monat].AbtauStunden);
      end;

      // -- Stromverbrauch -------------------------------------------
      ElectricSpace :=
        WP.ElectricalPower(OutsideTemp, FlowTemp, WPHeatSpace);

      ElectricTWW :=
        WP.ElectricalPower(OutsideTemp, WP.TWWFlowTemp, WPHeatTWW);

      // Kurzzyklen-Mehrverbrauch nur auf den WP-Anteil (nicht auf den
      // Heizstab- oder Standby-Anteil, die von der WP-Taktung nicht
      // betroffen sind).
      if IstTaktRisiko then
      begin
        ElectricSpace := ElectricSpace * StartupVerlustFaktor;
        ElectricTWW := ElectricTWW * StartupVerlustFaktor;
      end;

      ElectricPower :=
        ElectricSpace + ElectricTWW + HeaterHeat + StandbyLeistung;

      CurrentCOP := WP.COP(OutsideTemp, FlowTemp);

      // -- Jahressummen (kW * 1h = kWh) -------------------------------
      Result.TotalHeat := Result.TotalHeat + HeatDemand;
      Result.TotalTWW := Result.TotalTWW + TWWDemand;
      Result.TotalElectric := Result.TotalElectric + ElectricPower;
      Result.TotalHeater := Result.TotalHeater + HeaterHeat;

      Result.Monate[Monat].Heat := Result.Monate[Monat].Heat + HeatDemand;
      Result.Monate[Monat].TWW := Result.Monate[Monat].TWW + TWWDemand;
      Result.Monate[Monat].Electric :=
        Result.Monate[Monat].Electric + ElectricPower;
      Result.Monate[Monat].Heater :=
        Result.Monate[Monat].Heater + HeaterHeat;

      Result.StundenAussen[Hour] := OutsideTemp;
      Result.StundenCOP[Hour] := CurrentCOP;

      // -- CSV-Export --------------------------------------------------
      Writeln(CSVFile,
        Format('%d;%.2f;%.2f;%.3f;%.3f;%.3f;%.3f;%.3f;%.2f;%.3f;%d;%d;%d',
          [Hour, OutsideTemp, FlowTemp, HeatDemand, TWWDemand,
           WPHeatSpace, WPHeatTWW, HeaterHeat, CurrentCOP,
           ElectricPower, Ord(IstTaktRisiko), Ord(IstAbtauRisiko),
           AktiveWPs],
          CSVFormat));

      // -- Konsolen-Beispielausgabe ------------------------------------
      if ShowConsoleDetails and (Hour mod 720 = 0) then
      begin
        Writeln(
          Format(
            'Stunde %4d: Aussen=%6.1f C  VL=%5.1f C  ',
            [Hour, OutsideTemp, FlowTemp]));

        Writeln(
          Format(
            '             Bedarf=%5.2f kW  TWW=%5.2f kW  WP=%5.2f kW  ',
            [HeatDemand, TWWDemand, WPHeatSpace + WPHeatTWW]));

        Writeln(
          Format(
            '             COP=%4.2f  Strom=%5.2f kW',
            [CurrentCOP, ElectricPower]));

        Writeln;
      end;
    end;
  finally
    CloseFile(CSVFile);
  end;

  if Result.TotalElectric > 0 then
    Result.JAZ :=
      (Result.TotalHeat + Result.TotalTWW) / Result.TotalElectric
  else
    Result.JAZ := 0;

  if Result.ActiveHours > 0 then
    Result.TaktRisikoAnteil :=
      100.0 * Result.TaktRisikoStunden / Result.ActiveHours
  else
    Result.TaktRisikoAnteil := 0;

  if ShowConsoleDetails then
  begin
    Writeln(
      Format('  -> stuendliche Ergebnisse geschrieben nach: %s',
        [CSVFileName]));
    Writeln;
  end;
end;

end.
