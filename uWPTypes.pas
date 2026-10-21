unit uWPTypes;

{$mode objfpc}{$H+}

// ================================================================
// Grunddatentypen der Waermepumpen-Simulation: Heizkurve, Kennfeld,
// die Klassenhierarchie TWaermeErzeuger/TWaermepumpe/
// TWaermepumpenKaskade sowie TGebaeude. Enthaelt bewusst KEINE
// Simulationslogik (siehe uSimulation) und KEINE Ein-/Ausgabe (siehe
// uWetterdaten, uKonfiguration, uBericht) - nur das reine
// Datenmodell, damit diese Unit von allen anderen ohne Umwege
// verwendet werden kann.
// ================================================================

interface

uses
  SysUtils;

type
  TDoubleArray = array of Double;

  // Zwei Stuetzpunkte definieren die Heizkurve (lineare Kennlinie):
  //   - Fusspunkt:   milde Aussentemperatur  -> niedrige Vorlauftemp.
  //   - Auslegung:   Norm-Aussentemperatur   -> Auslegungsvorlauf
  THeizkurve = record
    FusspunktAussen: Double;   // z.B. 15 °C
    FusspunktVorlauf: Double;  // z.B. 25 °C
    AuslegungAussen: Double;   // z.B. -12 °C (Normaussentemperatur)
    AuslegungVorlauf: Double;  // z.B. 45 °C
  end;

  // Klassisches Kennfeld: N Aussentemperaturen x M Vorlauftemperaturen
  // (z.B. 3x2: -7/2/7 °C x 35/55 °C, wie ueblicherweise im Datenblatt -
  // aber beliebig viele Stuetzstellen in beide Richtungen moeglich, um
  // z.B. auch einen zusaetzlichen Punkt bei -15 °C oder eine dritte
  // Vorlauftemperatur wie 45 °C einzutragen). AWerte und WWerte muessen
  // aufsteigend sortiert sein. Ausserhalb des Rasters wird linear
  // extrapoliert (mit der Steigung des jeweils aeussersten Segments)
  // statt einfach abzuschneiden - siehe InterpolateKennfeld.
  TKennfeld = record
    AWerte: TDoubleArray;             // z.B. [-7, 2, 7]
    WWerte: TDoubleArray;             // z.B. [35, 55]
    COP: array of TDoubleArray;       // COP[Aussen-Index][Vorlauf-Index]
    Leistung: array of TDoubleArray;  // kW,  [Aussen-Index][Vorlauf-Index]
  end;

  // ----------------------------------------------------------------
  // Gemeinsame Schnittstelle fuer alles, was im Simulationskern
  // ("RunSimulation" in uSimulation) als "Waermeerzeuger" fuer ein
  // Gebaeude auftreten kann: eine einzelne Waermepumpe (TWaermepumpe)
  // oder mehrere im Kaskadenverbund (TWaermepumpenKaskade).
  // RunSimulation kennt nur diese abstrakte Schnittstelle - die
  // eigentliche Logik je Einheit bzw. je Kaskade steckt vollstaendig
  // in den jeweiligen Klassen.
  // ----------------------------------------------------------------
  TWaermeErzeuger = class
  protected
    function GetName: string; virtual; abstract;
    function GetTWWFlowTemp: Double; virtual; abstract;
    function GetAnzahlEinheiten: Integer; virtual; abstract;
  public
    function FlowTemperature(OutsideTemp: Double): Double; virtual; abstract;
    function MaxHeatingPower(OutsideTemp, FlowTemp: Double): Double;
      virtual; abstract;
    function MinHeatingPower(OutsideTemp, FlowTemp: Double): Double;
      virtual; abstract;
    function ElectricalPower(OutsideTemp,
      FlowTemp, HeatingPower: Double): Double; virtual; abstract;
    function COP(OutsideTemp, FlowTemp: Double): Double; virtual; abstract;
    function AbtauRisikoBedingung(OutsideTemp: Double): Boolean;
      virtual; abstract;
    // Wie viele Einheiten bei der gegebenen Gesamt-Heizleistung
    // tatsaechlich laufen (bei einer einzelnen WP: 0 oder 1; bei einer
    // Kaskade: je nachdem, wie viele Einheiten zur Deckung der
    // Anforderung zugeschaltet werden muessen - siehe
    // TWaermepumpenKaskade).
    function AktiveEinheiten(OutsideTemp, FlowTemp,
      HeatingPowerTotal: Double): Integer; virtual; abstract;

    property Name: string read GetName;
    property TWWFlowTemp: Double read GetTWWFlowTemp;
    // Gesamtzahl der Einheiten (Waermepumpe: immer 1; Kaskade: Anzahl
    // der Einheiten im Verbund).
    property AnzahlEinheiten: Integer read GetAnzahlEinheiten;
  end;

  TWaermepumpe = class(TWaermeErzeuger)
  private
    FName: string;
    FMinTemp: Double;         // °C, Einsatzgrenze - darunter keine Heizleistung mehr
    FMaxFlowTemp: Double;     // °C, technisches Limit der WP
    FHeizkurve: THeizkurve;
    FTWWFlowTemp: Double;     // °C Vorlauf fuer Trinkwarmwasser
    FKennfeld: TKennfeld;
    FMinModulationAnteil: Double;  // z.B. 0.3 = 30 % der aktuellen Maxleistung
  protected
    function GetName: string; override;
    function GetTWWFlowTemp: Double; override;
    function GetAnzahlEinheiten: Integer; override;
  public
    constructor Create(const AName: string;
      AMinTemp, AMaxFlowTemp, ATWWFlowTemp, AMinModulationAnteil: Double;
      AHeizkurve: THeizkurve; AKennfeld: TKennfeld);

    function FlowTemperature(OutsideTemp: Double): Double; override;
    function DefrostFactor(OutsideTemp: Double): Double;
    function AbtauRisikoBedingung(OutsideTemp: Double): Boolean; override;
    function COP(OutsideTemp, FlowTemp: Double): Double; override;
    function MaxHeatingPower(OutsideTemp, FlowTemp: Double): Double; override;
    function MinHeatingPower(OutsideTemp, FlowTemp: Double): Double; override;
    function ElectricalPower(OutsideTemp,
      FlowTemp, HeatingPower: Double): Double; override;
    function AktiveEinheiten(OutsideTemp, FlowTemp,
      HeatingPowerTotal: Double): Integer; override;
  end;

  // ----------------------------------------------------------------
  // Kaskade aus mehreren Waermepumpen-Einheiten, die sich einen
  // hydraulischen Kreis teilen und sequenziell je nach Bedarf
  // zugeschaltet werden - so arbeiten die meisten realen
  // Kaskadenregelungen: die ERSTE Einheit der Liste moduliert normal
  // zwischen ihrer Mindest- und Maxleistung; reicht ihre Leistung
  // nicht aus, wird die zweite Einheit voll zugeschaltet und deckt
  // den Rest, reicht das immer noch nicht, die dritte usw. Die
  // Einheiten duerfen unterschiedlich gross sein (gemischte Kaskade,
  // z.B. eine kleine Grundlast- + eine groessere Spitzenlast-Einheit).
  //
  // Wichtige Vereinfachung: alle Einheiten haengen am selben
  // hydraulischen Kreis, daher gibt die ERSTE (Fuehrungs-)Einheit mit
  // ihrer Heizkurve und TWW-Vorlauftemperatur die fuer die gesamte
  // Kaskade gueltige Vorlauftemperatur vor - die Heizkurven der
  // weiteren Einheiten werden dann nicht genutzt. Fuer eine moeglichst
  // niedrige Taktrisiko-Schwelle sollte deshalb die KLEINSTE Einheit
  // der Kaskade als erste in der Liste stehen: dann uebernimmt bei
  // Schwachlast die am feinsten modulierbare (kleinste) Einheit allein,
  // genau das ist der praktische Vorteil einer Kaskade gegenueber
  // einer einzelnen groesseren Waermepumpe.
  // ----------------------------------------------------------------
  TWaermepumpenKaskade = class(TWaermeErzeuger)
  private
    FName: string;
    FEinheiten: array of TWaermepumpe;  // Reihenfolge = Zuschaltreihenfolge
  protected
    function GetName: string; override;
    function GetTWWFlowTemp: Double; override;
    function GetAnzahlEinheiten: Integer; override;
  public
    constructor Create(const AName: string;
      const AEinheiten: array of TWaermepumpe);
    destructor Destroy; override;

    function FlowTemperature(OutsideTemp: Double): Double; override;
    function MaxHeatingPower(OutsideTemp, FlowTemp: Double): Double; override;
    function MinHeatingPower(OutsideTemp, FlowTemp: Double): Double; override;
    function ElectricalPower(OutsideTemp,
      FlowTemp, HeatingPower: Double): Double; override;
    function COP(OutsideTemp, FlowTemp: Double): Double; override;
    function AbtauRisikoBedingung(OutsideTemp: Double): Boolean; override;
    function AktiveEinheiten(OutsideTemp, FlowTemp,
      HeatingPowerTotal: Double): Integer; override;
  end;

  TGebaeude = class
  private
    FName: string;
    FHeatLoss: Double;        // kW/K
    FIndoorTemp: Double;      // °C
    FTWWDemandDaily: Double;  // kWh/Tag Trinkwarmwasser
    FAltWirkungsgrad: Double;    // Wirkungsgrad der bisherigen Heizung (0..1)
    FAltBrennstoffpreis: Double; // EUR/kWh Brennstoff der bisherigen Heizung
  public
    constructor Create(const AName: string;
      AHeatLoss, AIndoorTemp, ATWWDemandDaily,
      AAltWirkungsgrad, AAltBrennstoffpreis: Double);

    function HeatingDemand(OutsideTemp: Double): Double;
    function TWWDemand(Hour: Integer): Double;  // kW in dieser Stunde

    property Name: string read FName;
    property AltWirkungsgrad: Double read FAltWirkungsgrad;
    property AltBrennstoffpreis: Double read FAltBrennstoffpreis;
  end;

  // Ein vollstaendiges Szenario: eine Waermepumpe ODER eine Kaskade
  // (TWP ist von beidem der gemeinsame Vorfahr) zusammen mit dem
  // Gebaeude, gegen das sie simuliert wird. Wird von uKonfiguration
  // beim Einlesen der INI-Datei befuellt und von RunSimulation/
  // GenerateHTMLReport konsumiert.
  TSzenarioKonfiguration = record
    WP: TWaermeErzeuger;
    Gebaeude: TGebaeude;
  end;
  TSzenarioKonfigurationArray = array of TSzenarioKonfiguration;

// ================================================================
// Kennfeld-Interpolation
//
// Datenblaetter geben COP und Heizleistung ueblicherweise an einem
// Raster aus Aussentemperaturen x Vorlauftemperaturen an (klassisch
// 3x2: -7/2/7 °C x 35/55 °C, aber z.B. auch mit einem zusaetzlichen
// Punkt bei -15 °C oder einer dritten Vorlauftemperatur wie 45 °C -
// AWerte/WWerte duerfen beliebig lang sein). Fuer Betriebspunkte
// dazwischen wird linear interpoliert, ausserhalb des Rasters mit der
// Steigung des jeweils aeussersten Segments extrapoliert (kein hartes
// Abschneiden).
// ================================================================

// Lineare Interpolation/stueckweise Extrapolation entlang einer Achse
// mit beliebig vielen (mind. 2) aufsteigend sortierten Stuetzstellen
// Xs/Ys. Fuer X ausserhalb [Xs[0], Xs[High]] wird mit der Steigung des
// jeweils aeussersten Segments extrapoliert.
function Interp1D(const Xs, Ys: TDoubleArray; X: Double): Double;

procedure InterpolateKennfeld(const KF: TKennfeld;
  OutsideTemp, FlowTemp: Double; out COPResult, LeistungResult: Double);

// Baut ein Kennfeld aus den Aussentemperatur-/Vorlauftemperatur-
// Stuetzstellen sowie den (COP, Leistung)-Werten des Datenblatts.
// COPWerte/LeistungWerte werden zeilenweise nach Aussentemperatur
// erwartet (fuer jede Aussentemperatur alle Vorlaufwerte der Reihe
// nach) - also genau so, wie eine Datenblatt-Tabelle zeilenweise
// gelesen wird: Laenge = Length(AWerte) * Length(WWerte).
function MacheKennfeld(const AWerte, WWerte: array of Double;
  const COPWerte, LeistungWerte: array of Double): TKennfeld;

function MacheHeizkurve(FPAussen, FPVorlauf, AusAussen,
  AusVorlauf: Double): THeizkurve;

implementation

function Interp1D(const Xs, Ys: TDoubleArray; X: Double): Double;
var
  I: Integer;
begin
  if X <= Xs[0] then
  begin
    Result := Ys[0] + (Ys[1] - Ys[0]) * (X - Xs[0]) / (Xs[1] - Xs[0]);
    Exit;
  end;

  if X >= Xs[High(Xs)] then
  begin
    Result :=
      Ys[High(Xs) - 1] +
      (Ys[High(Xs)] - Ys[High(Xs) - 1]) *
      (X - Xs[High(Xs) - 1]) / (Xs[High(Xs)] - Xs[High(Xs) - 1]);
    Exit;
  end;

  Result := Ys[0];  // wird in der Schleife immer ueberschrieben
  for I := 0 to High(Xs) - 1 do
    if (X >= Xs[I]) and (X <= Xs[I + 1]) then
    begin
      Result := Ys[I] + (Ys[I + 1] - Ys[I]) *
        (X - Xs[I]) / (Xs[I + 1] - Xs[I]);
      Break;
    end;
end;

procedure InterpolateKennfeld(const KF: TKennfeld;
  OutsideTemp, FlowTemp: Double; out COPResult, LeistungResult: Double);
var
  RowCOP, RowLeistung: TDoubleArray;
  I: Integer;
begin
  // Schritt 1: fuer jede Aussentemperatur-Stuetzstelle entlang der
  // Vorlauftemperatur interpolieren/extrapolieren.
  SetLength(RowCOP, Length(KF.AWerte));
  SetLength(RowLeistung, Length(KF.AWerte));

  for I := 0 to High(KF.AWerte) do
  begin
    RowCOP[I] := Interp1D(KF.WWerte, KF.COP[I], FlowTemp);
    RowLeistung[I] := Interp1D(KF.WWerte, KF.Leistung[I], FlowTemp);
  end;

  // Schritt 2: die Zwischenwerte entlang der Aussentemperatur
  // interpolieren/extrapolieren.
  COPResult := Interp1D(KF.AWerte, RowCOP, OutsideTemp);
  LeistungResult := Interp1D(KF.AWerte, RowLeistung, OutsideTemp);
end;

function MacheKennfeld(const AWerte, WWerte: array of Double;
  const COPWerte, LeistungWerte: array of Double): TKennfeld;
var
  NA, NW, I, J: Integer;
begin
  NA := Length(AWerte);
  NW := Length(WWerte);

  if (NA < 2) or (NW < 2) then
    raise Exception.Create(
      'MacheKennfeld: mindestens 2 Aussentemperaturen und 2 ' +
      'Vorlauftemperaturen noetig.');

  if (Length(COPWerte) <> NA * NW) or (Length(LeistungWerte) <> NA * NW) then
    raise Exception.CreateFmt(
      'MacheKennfeld: %d Aussenwerte x %d Vorlaufwerte = %d Punkte ' +
      'erwartet, aber %d COP- und %d Leistungswerte erhalten.',
      [NA, NW, NA * NW, Length(COPWerte), Length(LeistungWerte)]);

  SetLength(Result.AWerte, NA);
  SetLength(Result.WWerte, NW);
  SetLength(Result.COP, NA);
  SetLength(Result.Leistung, NA);

  for I := 0 to NA - 1 do
    Result.AWerte[I] := AWerte[I];
  for I := 0 to NW - 1 do
    Result.WWerte[I] := WWerte[I];

  for I := 0 to NA - 1 do
  begin
    SetLength(Result.COP[I], NW);
    SetLength(Result.Leistung[I], NW);
    for J := 0 to NW - 1 do
    begin
      Result.COP[I][J] := COPWerte[I * NW + J];
      Result.Leistung[I][J] := LeistungWerte[I * NW + J];
    end;
  end;
end;

function MacheHeizkurve(FPAussen, FPVorlauf, AusAussen,
  AusVorlauf: Double): THeizkurve;
begin
  Result.FusspunktAussen := FPAussen;
  Result.FusspunktVorlauf := FPVorlauf;
  Result.AuslegungAussen := AusAussen;
  Result.AuslegungVorlauf := AusVorlauf;
end;


// ================================================================
// TWaermepumpe
// ================================================================

constructor TWaermepumpe.Create(const AName: string;
  AMinTemp, AMaxFlowTemp, ATWWFlowTemp, AMinModulationAnteil: Double;
  AHeizkurve: THeizkurve; AKennfeld: TKennfeld);
begin
  FName := AName;
  FMinTemp := AMinTemp;
  FMaxFlowTemp := AMaxFlowTemp;
  FTWWFlowTemp := ATWWFlowTemp;
  FMinModulationAnteil := AMinModulationAnteil;
  FHeizkurve := AHeizkurve;
  FKennfeld := AKennfeld;
end;

function TWaermepumpe.GetName: string;
begin
  Result := FName;
end;

function TWaermepumpe.GetTWWFlowTemp: Double;
begin
  Result := FTWWFlowTemp;
end;

function TWaermepumpe.GetAnzahlEinheiten: Integer;
begin
  Result := 1;
end;


// ------------------------------------------------------------
// Heizkurve (zwei Stuetzpunkte, linear extrapoliert)
// ------------------------------------------------------------

function TWaermepumpe.FlowTemperature(OutsideTemp: Double): Double;
var
  Steigung: Double;
begin
  // Steigung der Geraden durch Fusspunkt und Auslegungspunkt
  Steigung :=
    (FHeizkurve.AuslegungVorlauf - FHeizkurve.FusspunktVorlauf) /
    (FHeizkurve.AuslegungAussen - FHeizkurve.FusspunktAussen);

  Result :=
    FHeizkurve.FusspunktVorlauf +
    Steigung * (OutsideTemp - FHeizkurve.FusspunktAussen);

  if Result < FHeizkurve.FusspunktVorlauf then
    Result := FHeizkurve.FusspunktVorlauf;

  if Result > FMaxFlowTemp then
    Result := FMaxFlowTemp;
end;


// ------------------------------------------------------------
// Abtauverluste
//
// Vereinfachtes Modell: im Bereich von ca. -5 °C bis +5 °C kann
// sich am Verdampfer Reif/Eis bilden, das per Abtauzyklus entfernt
// werden muss. Das kostet Heizleistung und Strom. Das Maximum des
// Effekts wird bei ca. +1 °C angenommen (feuchtkalte Luft), zu den
// Raendern hin klingt er dreiecksfoermig ab.
// ------------------------------------------------------------

function TWaermepumpe.DefrostFactor(OutsideTemp: Double): Double;
const
  MaxVerlust = 0.12;   // bis zu 12 % Effizienzverlust
  Zentrum = 1.0;       // °C, Zentrum der Vereisungsgefahr
  Breite = 6.0;        // °C, Breite des betroffenen Bereichs
var
  Abstand: Double;
begin
  Abstand := Abs(OutsideTemp - Zentrum);

  if Abstand >= Breite then
    Result := 1.0
  else
    Result := 1.0 - MaxVerlust * (1.0 - Abstand / Breite);
end;


// ------------------------------------------------------------
// Abtau-Risiko-Bedingung (fuer die Kennzahl "Abtau-Risiko-Stunden")
//
// Enger als das breite Abschlagsband von DefrostFactor (das absicht-
// lich sanft ausklingt, um im COP keine Kante zu erzeugen): hier geht
// es nur darum, Stunden zu zaehlen, in denen tatsaechlich mit
// nennenswerter Reifbildung zu rechnen ist - klassischerweise der
// Bereich um 0 °C herum (ca. -3 bis +5 °C) bei Luft/Wasser-WP. Ohne
// Feuchtedaten ist das eine konservative, rein temperaturbasierte
// Abschaetzung (echte Vereisung braucht zusaetzlich hohe Luft-
// feuchte).
// ------------------------------------------------------------

function TWaermepumpe.AbtauRisikoBedingung(OutsideTemp: Double): Boolean;
const
  UntereGrenze = -3.0;  // °C
  ObereGrenze = 5.0;    // °C
begin
  Result := (OutsideTemp >= UntereGrenze) and (OutsideTemp <= ObereGrenze);
end;


// ------------------------------------------------------------
// COP
//
// Aus dem Datenblatt-Kennfeld interpoliert/extrapoliert (siehe
// InterpolateKennfeld) statt aus einer theoretischen Carnot-
// Naeherung. Der Abtauverlust-Faktor wird zusaetzlich angewendet,
// da die Datenblattpunkte nach EN 14511 im eingeschwungenen Zustand
// ohne Vereisung gemessen werden.
// ------------------------------------------------------------

function TWaermepumpe.COP(
  OutsideTemp, FlowTemp: Double): Double;
var
  KennfeldCOP, KennfeldLeistung: Double;
begin
  InterpolateKennfeld(FKennfeld, OutsideTemp, FlowTemp,
    KennfeldCOP, KennfeldLeistung);

  Result := KennfeldCOP * DefrostFactor(OutsideTemp);

  if Result < 0.0 then
    Result := 0.0;
end;


// ------------------------------------------------------------
// Maximale Heizleistung
//
// Ebenfalls aus dem Kennfeld interpoliert (Heizleistung haengt wie
// der COP von Aussen- UND Vorlauftemperatur ab). Unterhalb der
// Einsatzgrenze FMinTemp schaltet die Waermepumpe ganz ab - das
// steht i.d.R. separat im Datenblatt und nicht in der 3x2-Tabelle.
// ------------------------------------------------------------

function TWaermepumpe.MaxHeatingPower(
  OutsideTemp, FlowTemp: Double): Double;
var
  KennfeldCOP, KennfeldLeistung: Double;
begin
  if OutsideTemp < FMinTemp then
    Exit(0);

  InterpolateKennfeld(FKennfeld, OutsideTemp, FlowTemp,
    KennfeldCOP, KennfeldLeistung);

  Result := KennfeldLeistung;

  if Result < 0.0 then
    Result := 0.0;
end;


// ------------------------------------------------------------
// Minimale (modulierbare) Heizleistung
//
// Inverter-Waermepumpen koennen ihre Leistung nicht beliebig weit
// herunterregeln; unterhalb eines Anteils der aktuellen Maxleistung
// (FMinModulationAnteil) muessen sie takten (ein-/ausschalten), was
// Wirkungsgrad und Lebensdauer verschlechtert. Wird fuer das
// Taktrisiko in RunSimulation verwendet.
// ------------------------------------------------------------

function TWaermepumpe.MinHeatingPower(
  OutsideTemp, FlowTemp: Double): Double;
begin
  Result := MaxHeatingPower(OutsideTemp, FlowTemp) * FMinModulationAnteil;
end;


// ------------------------------------------------------------
// Elektrische Leistung
// ------------------------------------------------------------

function TWaermepumpe.ElectricalPower(
  OutsideTemp, FlowTemp, HeatingPower: Double): Double;
var
  CurrentCOP: Double;
begin
  if HeatingPower <= 0 then
    Exit(0);

  CurrentCOP := COP(OutsideTemp, FlowTemp);

  if CurrentCOP <= 0 then
    Exit(0);

  Result := HeatingPower / CurrentCOP;
end;


// ------------------------------------------------------------
// Aktive Einheiten (bei einer einzelnen WP: 0 oder 1)
// ------------------------------------------------------------

function TWaermepumpe.AktiveEinheiten(
  OutsideTemp, FlowTemp, HeatingPowerTotal: Double): Integer;
begin
  if HeatingPowerTotal > 0 then
    Result := 1
  else
    Result := 0;
end;


// ================================================================
// TWaermepumpenKaskade
//
// Verteilt eine angeforderte Heizleistung sequenziell auf die
// Einheiten (siehe Typdeklaration oben): Einheit 1 liefert bis zu
// ihrer eigenen Maxleistung, der Rest geht an Einheit 2, dann Einheit
// 3 usw. Jede Einheit laeuft dabei mit ihrem EIGENEN COP an der
// gemeinsamen Vorlauftemperatur - genau das ist der Vorteil einer
// Kaskade aus unterschiedlich grossen Einheiten gegenueber einer
// gleich grossen Einzel-WP.
// ================================================================

constructor TWaermepumpenKaskade.Create(const AName: string;
  const AEinheiten: array of TWaermepumpe);
var
  I: Integer;
begin
  inherited Create;

  if Length(AEinheiten) < 1 then
    raise Exception.Create(
      'TWaermepumpenKaskade: mindestens eine Einheit erforderlich.');

  FName := AName;
  SetLength(FEinheiten, Length(AEinheiten));
  for I := 0 to High(AEinheiten) do
    FEinheiten[I] := AEinheiten[I];
end;

destructor TWaermepumpenKaskade.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FEinheiten) do
    FEinheiten[I].Free;
  inherited Destroy;
end;

function TWaermepumpenKaskade.GetName: string;
begin
  Result := FName;
end;

function TWaermepumpenKaskade.GetTWWFlowTemp: Double;
begin
  // Die Fuehrungs-Einheit (erste in der Liste) gibt die gemeinsame
  // TWW-Vorlauftemperatur fuer die ganze Kaskade vor.
  Result := FEinheiten[0].TWWFlowTemp;
end;

function TWaermepumpenKaskade.GetAnzahlEinheiten: Integer;
begin
  Result := Length(FEinheiten);
end;

function TWaermepumpenKaskade.FlowTemperature(OutsideTemp: Double): Double;
begin
  // Alle Einheiten haengen am selben hydraulischen Kreis; die
  // Fuehrungs-Einheit (erste in der Liste) gibt die gemeinsame
  // Vorlauftemperatur vor (siehe Typdeklaration oben).
  Result := FEinheiten[0].FlowTemperature(OutsideTemp);
end;

function TWaermepumpenKaskade.MaxHeatingPower(
  OutsideTemp, FlowTemp: Double): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FEinheiten) do
    Result := Result + FEinheiten[I].MaxHeatingPower(OutsideTemp, FlowTemp);
end;

// Taktrisiko-Schwelle der Kaskade: solange die Anforderung niedrig
// genug ist, dass nur die erste (Fuehrungs-)Einheit laeuft, gilt
// deren eigene Mindestleistung - genau wie bei einer einzelnen WP.
// Bei hoeherer Anforderung sind bereits zugeschaltete weitere
// Einheiten an ihrer eigenen Maxleistung (nicht am Takten), daher
// bleibt diese Schwelle auch dort die richtige Vergleichsgroesse.
// Deshalb lohnt es sich, die KLEINSTE Einheit als Fuehrung zu waehlen
// (siehe Typdeklaration oben) - das drueckt diese Schwelle und damit
// das Taktrisiko der ganzen Kaskade.
function TWaermepumpenKaskade.MinHeatingPower(
  OutsideTemp, FlowTemp: Double): Double;
begin
  Result := FEinheiten[0].MinHeatingPower(OutsideTemp, FlowTemp);
end;

function TWaermepumpenKaskade.ElectricalPower(
  OutsideTemp, FlowTemp, HeatingPower: Double): Double;
var
  I: Integer;
  Rest, Anteil: Double;
begin
  Result := 0;
  Rest := HeatingPower;

  for I := 0 to High(FEinheiten) do
  begin
    if Rest <= 0 then
      Break;

    Anteil := FEinheiten[I].MaxHeatingPower(OutsideTemp, FlowTemp);
    if Anteil > Rest then
      Anteil := Rest;

    Result := Result +
      FEinheiten[I].ElectricalPower(OutsideTemp, FlowTemp, Anteil);
    Rest := Rest - Anteil;
  end;
end;

// Repraesentativer COP der Kaskade bei dieser Aussen-/Vorlauf-
// temperatur, unabhaengig von der aktuellen Anforderung: mit der
// jeweiligen Maxleistung gewichteter Mittelwert der Einzel-COPs. Fuer
// das Streudiagramm im HTML-Bericht und die Konsolenausgabe - die
// tatsaechliche, lastabhaengige Aufteilung passiert in
// ElectricalPower.
function TWaermepumpenKaskade.COP(OutsideTemp, FlowTemp: Double): Double;
var
  I: Integer;
  Leistung, SummeLeistung, SummeLeistungMalCOP: Double;
begin
  SummeLeistung := 0;
  SummeLeistungMalCOP := 0;

  for I := 0 to High(FEinheiten) do
  begin
    Leistung := FEinheiten[I].MaxHeatingPower(OutsideTemp, FlowTemp);
    SummeLeistung := SummeLeistung + Leistung;
    SummeLeistungMalCOP := SummeLeistungMalCOP +
      Leistung * FEinheiten[I].COP(OutsideTemp, FlowTemp);
  end;

  if SummeLeistung > 0 then
    Result := SummeLeistungMalCOP / SummeLeistung
  else
    Result := 0;
end;

// Abtau-Risiko der Kaskade: sobald mindestens eine Einheit im
// vereisungsgefaehrdeten Bereich liegt (bei Einheiten desselben Typs
// praktisch immer alle gleichzeitig, da nur von der Aussentemperatur
// abhaengig).
function TWaermepumpenKaskade.AbtauRisikoBedingung(
  OutsideTemp: Double): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(FEinheiten) do
    if FEinheiten[I].AbtauRisikoBedingung(OutsideTemp) then
    begin
      Result := True;
      Break;
    end;
end;

function TWaermepumpenKaskade.AktiveEinheiten(
  OutsideTemp, FlowTemp, HeatingPowerTotal: Double): Integer;
var
  I: Integer;
  Rest, Anteil: Double;
begin
  Result := 0;
  Rest := HeatingPowerTotal;

  for I := 0 to High(FEinheiten) do
  begin
    if Rest <= 0 then
      Break;

    Anteil := FEinheiten[I].MaxHeatingPower(OutsideTemp, FlowTemp);
    if Anteil > Rest then
      Anteil := Rest;

    if Anteil > 0 then
      Inc(Result);

    Rest := Rest - Anteil;
  end;
end;


// ================================================================
// TGebaeude
// ================================================================

constructor TGebaeude.Create(const AName: string;
  AHeatLoss, AIndoorTemp, ATWWDemandDaily,
  AAltWirkungsgrad, AAltBrennstoffpreis: Double);
begin
  FName := AName;
  FHeatLoss := AHeatLoss;
  FIndoorTemp := AIndoorTemp;
  FTWWDemandDaily := ATWWDemandDaily;
  FAltWirkungsgrad := AAltWirkungsgrad;
  FAltBrennstoffpreis := AAltBrennstoffpreis;
end;


// ------------------------------------------------------------
// Heizbedarf
// ------------------------------------------------------------

function TGebaeude.HeatingDemand(
  OutsideTemp: Double): Double;
var
  DeltaT: Double;
begin
  DeltaT := FIndoorTemp - OutsideTemp;

  if DeltaT <= 0 then
    Result := 0
  else
    Result := FHeatLoss * DeltaT;
end;


// ------------------------------------------------------------
// Trinkwarmwasser-Bedarf
//
// Vereinfachtes Tagesprofil: der taegliche kWh-Bedarf wird ueber
// zwei Zapf-Schwerpunkte (Morgen/Abend) verteilt, sodass die Summe
// ueber 24 Stunden dem vorgegebenen Tagesbedarf entspricht.
// ------------------------------------------------------------

function TGebaeude.TWWDemand(Hour: Integer): Double;
var
  StundeDesTages: Integer;
  Faktor: Double;
begin
  StundeDesTages := Hour mod 24;

  // Grundlast + zwei Zapfspitzen (6-9 Uhr, 18-22 Uhr)
  Faktor := 0.5;

  if (StundeDesTages >= 6) and (StundeDesTages < 9) then
    Faktor := 2.2;

  if (StundeDesTages >= 18) and (StundeDesTages < 22) then
    Faktor := 2.0;

  // Normierung: Summe der Faktoren über 24h fest verdrahtet
  // (17h * 0.5 + 3h * 2.2 + 4h * 2.0 = 23.1)
  Result := FTWWDemandDaily * Faktor / 23.1;
end;

end.
