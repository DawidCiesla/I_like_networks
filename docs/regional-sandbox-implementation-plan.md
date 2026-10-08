# Regionalny sandbox transportowy — plan implementacji

## Stan implementacji

Plan został rozszerzony podczas wdrażania; poniższy pierwotny audyt opisuje luki sprzed prac, a nie bieżący stan repozytorium.

Zaimplementowane w prototypie: startowy region bez predefiniowanej linii, wersjonowany opis mapy i edycje wysokości, drogi oraz wybór lokalizacji zajezdni, autonomiczny wzrost osad, zagregowany wybór podróży autem i transportem zbiorowym według relacji i kohort, przepływ popytu do pasażerów, finanse operatora, profile infrastruktury, warstwy terenu i wody oraz bazowe oświetlenie dobowe. Tryby autobus/tramwaj/metro mają progi odblokowania, parametry prędkości, pojemności i kosztów, ograniczenia tras oraz testy; rezerwacja torów tramwajowych jest walidowana atomowo. Ocena zdrowia i pokrycie ochroną zdrowotną są liczone per osada i kohorta z bieżących usług, czasu dojazdu, dobrostanu i modelowanej ekspozycji na podróże samochodem. Lepszy wynik zdrowia zwiększa atrakcyjność lokalizacji, a HUD pokazuje dostępność usług, obciążenie zdrowotne i następny cel.

To nadal prototyp systemów, nie zamknięty odbiór gry. W regionie działają usługi zdrowia, edukacji, straży pożarnej, policji, odpadów i rekreacji: startowa pojemność jest ograniczona, a gracz może dobudować obiekt w osadzie, jeśli istnieje niezaspokojony popyt i ma środki. Zdrowie ma teraz wersjonowany stan kohort: obciążenia ostre i przewlekłe, leczenie, starzenie grup wieku, urodzenia i oczekiwane zgony aktualizują populację osad. Oddzielono też obserwowany wzrost miasta od zmian populacji obliczanych przez zdrowie, aby zgony i urodzenia nie były ponownie księgowane jako zewnętrzne zmiany. Wiek z tej symulacji kształtuje transport: dzieci nie mają opcji prowadzenia auta, seniorzy mają mniejszy udział dostępnych aut, krótszy zasięg pieszy oraz obniżoną taryfę, a ich udziały transportu można odczytać globalnie i dla osady. Różne profile piesze współdzielą trasowanie między tymi samymi parami przystanków. To abstrakcyjny model gry, nie symulacja pojedynczych diagnoz ani prognoza medyczna. Parametry używają przyspieszonego zegara gry i wymagają strojenia w dłuższym playteście. Trasy pasażerów porównują teraz czasy jazdy, oczekiwanie z cyklu i wielkości floty oraz presję zatłoczenia; autobusy i tramwaje przestrzegają profilu rozstawu przystanków. W sandboxie pasażerowie trafiają do pierwszej kolejki, a kolejne odcinki dostają wyłącznie grupy faktycznie obsłużone i wysadzone; pojemność i porzucanie kolejki proporcjonalnie zmieniają ich wagi taryfowe. Czas przejścia pieszego między liniami wpływa na kalkulację wyboru trasy, ale jeszcze nie opóźnia pojawienia się transferu w kolejce. Tramwajowe przejazdy są łączone per linia, ograniczając liczbę obiektów renderera. Zapis rotuje atomową kopię poprzedniej wersji i w razie uszkodzenia pliku głównego próbuje odzyskać poprawną kopię lub kompletny plik tymczasowy. HUD udostępnia eksport i wczytanie kopii JSON oraz potwierdzenie przed zastąpieniem autosave'a nowym regionem. Importer odrzuca cały zapis z nieobsługiwaną przyszłą wersją sieci, zamiast po cichu usuwać linie i pojazdy. Metro ma podziemny kontrakt routingu, dostępne stacje i symulowany pociąg oraz geometrię ścian i torów tunelu; shader wycina wąski pas terenu nad aktywną trasą, a grupowane szyby wentylacyjne wskazują jej przebieg. Przerywany ślad trasy i oznaczone wejścia pomagają czytać jej przebieg z powierzchni, ale metro nie przeszło ręcznego odbioru obrazu. Paleta wody różnicuje rzeki, jeziora i głębokość. Nie zakończono przeglądu artystycznego ani pomiarów docelowych 60 FPS na Windows, macOS i Linux. Premium/AAA stylizowana oprawa pozostaje aktywnym celem, a jakość wizualna kryterium do odbioru.

Poniższa kolejność etapów pochodzi z pierwotnego planu. Jej aktualny stan wygląda następująco:

| Etap | Stan w kodzie | Pozostały odbiór |
|---|---|---|
| 0. Start sandboxa | Wdrożony prototyp regionalny, seedowana mapa i odrębny tryb legacy; natywne kopie można eksportować i wczytywać, a zastąpienie autosave'a potwierdza się w HUD. | Ręczny przegląd zapisu/wczytania i scenariusza od nowej gry do dalszej rozbudowy. |
| 1. Drogi i zajezdnia | Gracz buduje regionalne drogi, wybiera miejsce zajezdni i tworzy własne linie; tramwaj otrzymał osobno renderowane tory i przejazdy, a metro podziemną geometrię tunelu z lokalnym wycięciem terenu. | Ręczny test pełnego przepływu narzędzi, czytelności stanów budowy i obrazu metra. |
| 2. Wzrost miasta | Wdrożony ograniczony, deterministyczny wzrost zależny od dostępu do dróg; transport poprawia priorytet lokalizacji, ale nie jest warunkiem wzrostu. | Strojenie tempa, limitów i widocznej informacji o przyczynach wzrostu. |
| 3. Popyt i wybór podróży | Wdrożone zagregowane relacje, dochód i wiek; dostęp do auta różni się według wieku i statusu, dzieci oraz seniorzy mają osobne zasięgi dojścia i taryfy, a wybór autobus/tramwaj/metro zasila kolejki pasażerów. Przesiadki kontynuują wyłącznie pasażerów obsłużonych na poprzedniej linii. | Playtest reakcji grup wieku i dochodu na taryfę, częstotliwość, pojemność, bariery oraz zmianę tras i dostępności; dodać opóźnienie transferu o dojście piesze. |
| 4. Ekonomia i usługi | Wdrożone wpływy z biletów, koszty działania transportu i obiektów usługowych, budowanie usług przez gracza oraz kohortowy model chorobowości, leczenia i demografii. | Strojenie progów, kosztów i efektów; sprawdzenie, czy decyzje są zrozumiałe i mają sens w dłuższej grze. |
| 5. Interfejs i jakość | HUD, narzędzia, inspektory osad, warstwy mapy, teren, woda i oświetlenie są w prototypie; trasa i wejścia metra mają oznaczenia powierzchniowe; CI parsuje projekt, uruchamia self-test i skrypty `*_test.gd`. | Ręczny przegląd obrazu i całej pętli, dopracowanie metra/usług oraz pomiary wydajności na systemach docelowych. |

## Cel pierwszego testowalnego wycinka

Gra ma sprawdzić jedną obietnicę: **gracz wybiera, gdzie i jak zbudować transport, a osady rozwijają się samodzielnie tam, gdzie infrastruktura daje mieszkańcom lepszy dostęp do pracy i usług**. Gracz zarządza siecią i jej finansami; nie wyznacza każdej parceli ani zachowania każdego mieszkańca.

Nowa gra ma być otwartym scenariuszem regionalnym. Nie opiera się na gotowej linii autobusowej, kolejnych zadaniach Line 1–4 ani kampanii Bus Era. Stary generator miasta i zapisy należy zachować dla zgodności, ale nie mogą sterować nowym scenariuszem.

## Uzgodniony kierunek rozgrywki

- **Gracz buduje infrastrukturę transportową:** strategiczne połączenia drogowe, zajezdnię, przystanki i linie; wybiera tryb, pojazdy, częstotliwość i taryfę. Autobus jest dostępny od początku, tramwaj i metro mają progi populacji oraz środków, a każdy tryb wymaga właściwego korytarza i przystanków/stacji.
- **Miasto buduje tkankę lokalną:** rozwija ulice osiedlowe, parcele, mieszkania i miejsca pracy. Wzrost zależy od dostępności, wolnej przestrzeni i ograniczeń terenu.
- **Transport zmienia atrakcyjność miejsc:** dobra dostępność transportem zbiorowym podnosi ocenę lokalizacji i pomaga przyciągać mieszkańców oraz działalność. Sam brak linii nie może całkowicie zatrzymać rozwoju.
- **Mieszkańcy są liczeni grupami, nie pojedynczymi agentami:** grupy popytu różnią się dochodem, liczbą pracujących i dostępem do samochodu; trzy kohorty wieku dziedziczą udział z modelu zdrowia, a wiek wpływa na dostępność auta, dojście do przystanku oraz taryfę. Wybór środka transportu wynika z czasu, kosztu i dostępności. HUD i inspektor osady pokazują osobny udział transportu publicznego dla dzieci i seniorów.
- **Dwie perspektywy sukcesu są widoczne osobno:** kondycja operatora oraz jakość dostępu i koszty ponoszone przez mieszkańców. HUD prowadzi przez odblokowania tramwaju/metra oraz opcjonalne cele dostępności regionalnej, równowagi kosztów operatora i pokrycia potrzeb zdrowotnych. Cele porządkują grę, ale nie blokują swobodnej rozbudowy.

Docelowa pętla:

```text
osady i miejsca pracy → podróże między osadami → wybór auta / transportu zbiorowego (autobus, tramwaj, metro) / podróży niezrealizowanej
          ↑                                                       ↓
autonomiczny wzrost ← lepszy dostęp i atrakcyjność ← linia, droga, częstotliwość i taryfa
```

## Pierwotny audyt — stan historyczny sprzed wdrożeń

Poniższe punkty zapisują stan repozytorium w chwili rozpoczęcia prac. Są kontekstem historycznym i nie opisują bieżących braków; aktualny stan oraz pozostałe zadania znajdują się na początku dokumentu i w sekcji „Co jest w zakresie, a co pozostaje”.

Audyt kodu wykazał następujące luki:

1. Nowa mapa nadal łączy `RegionPlanGenerator` ze starym `CityPlanGenerator`; stare korytarze transportowe mogą pojawić się jako zbudowane drogi. Logika kampanii i część komunikatów HUD nadal odnoszą się do linii 1–4 i Market Square.
2. Regionalne ulice i znaczniki zabudowy są w dużej mierze ustawiane jako gotowe i zajęte na starcie. Brakuje więc pustej pojemności oraz procesu, w którym miasto rozwija się po rozpoczęciu gry.
3. Nie ma narzędzia do budowania dróg przez gracza ani wyboru miejsca zajezdni. Edycja linii autobusowej istnieje, ale zależy od starego układu i postępu.
4. Dane populacji i miejsc pracy są agregatami. Dzisiejszy popyt transportowy linii stałych jest zadany ręcznie, a popyt linii niestandardowych jest tylko przybliżany liczbą pobliskich zabudowań. Nie ma porównania kosztu podróży autobusem i samochodem.
5. Autobusy, pojemność, wsiadanie, wysiadanie i wpływy z biletów są już symulowane, ale nie ma regularnych kosztów eksploatacji. Widoczne samochody są dekoracją, nie alternatywnym trybem podróży.
6. Zapis obejmuje miasto, lecz wersjonowanie miasta może zastąpić niezgodny stan zamiast go migrować. Rozwój i infrastruktura muszą być odporne na zapis/odczyt.
7. Testy generatora i integracji są w projekcie, ale pipeline CI nie uruchamia całego zestawu testów. Potrzebny jest też ręczny przegląd działającej gry, bo testy headless nie wykryją problemów obrazu i obsługi.

Szczególnie ważne jest rozdzielenie trzech rzeczy: **istniejącego świata**, **infrastruktury zbudowanej przez gracza** i **tkanki miejskiej dobudowanej przez symulację**. Ich wspólny zapis nie może zacierać źródła ani stanu obiektu.

## Zakres pierwszego grywalnego wycinka

Proponowany scenariusz startowy ma region kilku osad, jeden istniejący ośrodek z niewielką, działającą zabudową, wolne tereny rozwojowe i niepełną sieć połączeń strategicznych. Lokalne uliczki i część dróg dojazdowych mogą już istnieć; kluczowe połączenia między ośrodkami pozostają wyborem gracza. Nie ma gotowej linii ani aktywnej zajezdni.

W zaktualizowanym teście gracz powinien móc:

1. uruchomić nową grę sandboxową na powtarzalnym seedzie;
2. wybrać sensowne połączenie lub ulepszenie drogi, zbudować je za widoczny koszt i zobaczyć jego stan;
3. wybudować zajezdnię, kupić autobus i utworzyć własną linię; następnie sprawdzić progi tramwaju i metra, rezerwację torów, dostępność stacji metra i ograniczenia tras;
4. uruchomić usługę, zmienić jej częstotliwość lub taryfę i zobaczyć różnice między kohortami oraz faktyczne wejścia pasażerów do pojazdów;
5. dobudować obiekt usługi w osadzie z niezaspokojonym popytem, zobaczyć koszt budowy i działania oraz zmianę pokrycia opieki;
6. po upływie czasu zobaczyć autonomiczny rozwój miejsca z dostępem drogowym oraz wpływ dostępności transportowej na atrakcyjność lokalizacji;
7. odczytać saldo i koszty operatora/usług obok czasu podróży, obciążenia taryfą, dostępności miejsc pracy, podróży niezrealizowanych i wskaźników zdrowia kohort;
8. użyć widoków i narzędzi bez martwych stanów, sprawdzić czytelność dróg, przystanków, stacji, obiektów usługowych oraz postępu budowy;
9. zapisać grę, wczytać ją ponownie i kontynuować bez utraty lub powielenia obiektów.

To jest demonstracja związku **infrastruktura → dostępność → popyt i wybór środka transportu → rozwój osady**, a nie próba dostarczenia wszystkich systemów przyszłej gry.

## Kontrakty symulacji

### Świat i obiekty

Nowa gra zapisuje `map_id`, `seed`, `generator_version`, granice scenariusza i wersję formatu zapisu. Stan świata należy rozróżniać co najmniej jako:

- istniejące elementy regionu;
- planowane, budowane i ukończone elementy postawione przez gracza;
- planowane i ukończone elementy wybudowane przez miasto.

Ulice lokalne wygenerowane przez miasto nie mogą być traktowane jak strategiczne drogi gracza i same odblokowywać dalszych osad. Generowanie na ustalonym seedzie i wersji musi być deterministyczne. Reset ma odtwarzać aktualny scenariusz, a rozpoczęcie innej gry nie może nadpisywać istniejącego zapisu bez świadomej decyzji. Migracja starych zapisów nie może po cichu usuwać postępu; stary scenariusz można zachować jako zapis legacy lub jawny importer, ale nowa gra zawsze uruchamia sandbox.

### Zagregowany popyt i wybór środka transportu

Model liczy popyt na poziomie relacji osada–osada i niewielkiej liczby kohort. Różnice między grupami popytu obejmują liczbę pracujących, dochód oraz udział osób uprawnionych i mających dostęp do auta. Osobny model zdrowia śledzi zagregowane kohorty dzieci, dorosłych i seniorów; żaden z tych modeli nie tworzy agenta dla każdej osoby.

Miejsca pracy są celami podróży; na początek istniejące proporcje pracujących i miejsc pracy służą jako jawny parametr startowy, nie docelowy system gospodarki. Popyt rozkłada się na cele z uwzględnieniem dostępnych miejsc pracy oraz oporu czasu lub odległości.

Dla każdej kohorty i relacji model wylicza dostępne opcje: samochód, autobus, tramwaj lub metro oraz podróż niezrealizowaną. Czas i dostępność zależą od korytarza właściwego dla trybu; transport niedostępny dla danej relacji nie dostaje udziału. Dla każdej dostępnej opcji model wylicza:

- czas autem z dróg i ich limitów prędkości, jeśli dana kohorta ma dostęp do samochodu;
- czas transportem zbiorowym: dojście, oczekiwanie, przejazd, przesiadki i dojście końcowe, jeśli istnieje osiągalna usługa;
- koszt pieniężny i uogólniony koszt czasu oraz pieniędzy, z większą wrażliwością na cenę dla grup o niższych dochodach;
- podział podróży na auto, dostępne tryby transportu zbiorowego i podróż niezrealizowaną.

Mieszany udział wyboru może być liczony prostym modelem logitowym nad dostępnymi opcjami. Parametry należy wystawić w jednym miejscu i pokazać wynik w diagnostyce. Niedostępny środek transportu nie dostaje udziału. W pierwszym wycinku nie symulujemy pełnego ruchu samochodowego, korków ani indywidualnego routingu aut.

Sumy podróży muszą się bilansować. Przepływ przypisany do kursujących linii zasila kolejki OD, limity pojemności i zdarzenia wsiadania/wysiadania, tak aby wyliczony popyt nie był fikcyjnym wskaźnikiem bez związku z pasażerami w pojeździe.

### Finanse, usługi i dobrostan

Wspólne saldo publiczne finansuje drogi, zajezdnię, pojazdy i obiekty usługowe. Rachunek odróżnia nakłady kapitałowe, wpływy z biletów oraz bieżące koszty transportu i usług. Taryfy i przesiadki potrzebują jednej jawnej reguły naliczania opłaty.

Mieszkańcy nie obciążają ani nie zasilają bezpośrednio salda operatora. Wskaźniki pokazują średni czas dojazdu, wydatek transportowy i jego udział w dochodzie, dostęp do miejsc pracy, podróże niezrealizowane oraz dostępność usług. Zdrowie jest osobnym modelem zagregowanym dla kohort: dostęp do leczenia, dojazd, dobrostan i ekspozycja zmieniają przypadki ostre i przewlekłe, powroty do zdrowia oraz oczekiwaną śmiertelność. Urodzenia i starzenie przesuwają populację między kohortami; ułamkowe wartości są zachowywane w stanie, a liczebność miasta zaokrąglana do HUD-u. Nie tworzy to indywidualnych diagnoz. Usługi są liczone przez popyt, zasięg i pojemność obiektów, bez symulacji personelu ani kolejek.

### Autonomiczny wzrost osad

Generator dostarcza kandydatów do rozwoju, a symulacja wybiera je w powolnych, stałych krokach. Kandydat musi mieć możliwy dostęp do ukończonej strategicznej drogi, wolne miejsce i akceptowalne nachylenie/wodę. Aktywny przystanek i dostępność pracy zwiększają atrakcyjność lokalizacji, ale brak transportu zbiorowego nie blokuje całej gry.

Rozwój miasta korzysta z limitów wolnej ziemi, popytu, lokalnej infrastruktury, czasu od poprzedniej inwestycji i liczby aktywnych projektów. Miasto może zaplanować lokalną ulicę, parcelę i budynek, po czym wykonać je przez widoczny stan budowy. Wzrost na jednym lokalnym odcinku nie może sam uruchamiać nieograniczonej ekspansji regionu.

## Etapy implementacji i kryteria odbioru

Poniższe etapy zachowują kolejność i kryteria z pierwotnego planu. Funkcje wymienione jako zaimplementowane nie są ponownie otwartymi zadaniami; ich bieżący stan oraz nierozstrzygnięte prace podsumowuje tabela na początku dokumentu. Pełne spełnienie kryteriów grywalności nadal wymaga testu ręcznego.

### Etap 0 — Zamrożenie zakresu i czysty start sandboxa — wdrożono prototyp

- Ustalić nowy scenariusz `starter-region` jako jedyny aktywny tryb nowej gry.
- Oddzielić tworzenie miasta legacy od tworzenia regionu sandboxowego; usunąć z nowego startu fikcyjne korytarze linii 1–4 i stare cele HUD.
- Zdefiniować walidowany opis scenariusza: seed, granice mapy, zasoby startowe i wersję generatora; generator ma respektować granice.
- Zdefiniować minimalny istniejący rdzeń, wolne osady i częściowo niegotową sieć strategiczną. Nowy/resetowany scenariusz powinien czyścić także selekcję, narzędzia, stan terenu i tranzyt.
- Spisać niezmienniki formatu mapy, źródła obiektów i migracji zapisów.

**Odbiór:** nowa gra nie ma aktywnej linii, zajezdni ani odziedziczonych dróg udających inwestycje gracza; te same parametry tworzą tę samą mapę, zmiana seeda zmienia ją, wszystkie obiekty mieszczą się w granicach, a reset nie niszczy dotychczasowego zapisu.

### Etap 1 — Drogi strategiczne i zajezdnia wybierane przez gracza — wdrożono prototyp

- Dodać prosty tryb budowy odcinka drogowego: początek/koniec, przyciąganie do istniejącej sieci, walidację zasięgu i terenu, koszt, anulowanie oraz stan planowania/budowy/gotowości.
- Pozwolić zbudować zajezdnię na prawidłowej działce przy ukończonej drodze.
- Zostawić edytor linii osobnym od budowy drogi; autobus i tramwaj korzystają z ukończonych korytarzy drogowych, a metro wymaga wydzielonej trasy podziemnej.
- Utrzymać kilka czytelnych klas dróg. Tramwaj i metro należą do obecnego zakresu; bazowa geometria tunelu, lokalne wycięcie terenu i ruch pociągu już działają, ale ich czytelność wymaga ręcznego sprawdzenia i dopracowania.

**Odbiór:** niepoprawna lub nieosiągalna inwestycja nie pobiera pieniędzy; droga łączy graf po ukończeniu; zapis/odczyt zachowuje obiekty i ich źródło.

### Etap 2 — Autonomiczne, kontrolowane dojrzewanie miasta — wdrożono prototyp

- Rozdzielić początkową zabudowę od rezerwy parceli i punktów możliwej ekspansji.
- Dodać deterministyczny wybór kandydata na stałych krokach symulacji oraz wolne, ograniczone projekty lokalnych ulic i budynków.
- Ocenić dojazd drogowy, dostęp do pracy, teren, wolną pojemność i dostępność przystanków.
- Zapewnić, że wzrost jest możliwy przy braku linii, lecz szybciej lub w lepszych miejscach następuje po poprawie dostępności.

**Odbiór:** bez autobusu rośnie osiągalny przez drogę obszar; po uruchomieniu linii wybrane porównywalne obszary zyskują większy wynik atrakcyjności; odległa, odcięta lub zalana działka nie rośnie.

### Etap 3 — Popyt, kohorty i wybór trybu podróży — wdrożono prototyp

- Dodać czysty, deterministyczny moduł kalkulacji popytu i uogólnionych kosztów.
- Wyświetlać diagnostyczne przepływy i zasilać istniejące kolejki oraz pojemności pojazdów popytem przypisanym do dostępnej linii.
- Wystawić wynik podziału podróży, czas, koszt podróży i podróże niezrealizowane według kohort i relacji.
- Wykonać analizy wrażliwości: zmiana ceny, częstotliwości, prędkości i dojścia do przystanku musi dawać intuicyjny efekt.

**Odbiór:** trybu transportu nie wybiera nikt bez osiągalnej, poprawnej dla niego trasy; kohorta bez auta nie wybiera auta; zmiana czasu, dostępności lub kosztu zmienia udział odpowiedniej opcji; droższa taryfa obciąża silniej uboższą kohortę; sumy podróży nie znikają i nie są liczone wielokrotnie. Tramwaj wymaga zbudowanego korytarza z rezerwacją torów, a metro — wydzielonej trasy podziemnej oraz dostępnych stacji o poprawnym rozstawie.

### Etap 4 — Ekonomia, usługi i pętla rozwoju — wdrożono prototyp

- Rozliczać inwestycje, przychody z biletów oraz koszty działania transportu i obiektów usługowych.
- Ustalić zachowanie naliczania taryfy przy przesiadce i pokazać wpływ netto działania linii.
- Połączyć poprawioną dostępność z oceną lokalizacji, następnie z przyrostem mieszkańców i miejsc pracy z opóźnieniem.
- Umożliwić budowę obiektów usług w osadzie z niepełnym pokryciem; pokazać koszt budowy, koszty działania i efekt pojemności/zasięgu.
- Uwzględniać stan zdrowia zagregowanych kohort oraz jego związki z usługami, dojazdem, dobrostanem i ekspozycją samochodową; zachowywać przypadki, leczenie i demografię w wersjonowanym zapisie miasta.
- Utrzymać opcjonalne cele postępu dla dostępności, równowagi operatora i pokrycia ochroną zdrowotną, bez blokowania swobodnej rozgrywki.

**Odbiór:** uruchomienie nieopłacalnej usługi ma koszt; pauza symulacji zatrzymuje koszty okresowe; dostępna i użyteczna linia poprawia dostęp i może po czasie uruchomić autonomiczną inwestycję miasta; dobudowa brakującej usługi poprawia pokrycie; cele pokazują warunki i postęp w czytelny sposób.

### Etap 5 — Interfejs, oprawa, trwałość i wydajność — częściowo wdrożono

- Dopolerować istniejący HUD wokół narzędzi drogowych, zajezdni, linii i usług oraz stanów tramwaju/metra.
- Zachować oddzielne wskaźniki operatora i mieszkańców; poprawić etykiety, inspektory, podglądy trasy i komunikaty o ograniczeniach trybu.
- Dokończyć artystyczne rozróżnienie autobusów, tramwajów, metra i budynków usługowych. Zweryfikować ręcznie lokalne odkrycie tunelu i jadący pociąg metra, a następnie doszlifować przekrój, animację oraz stacje.
- Ręcznie sprawdzić widok całego regionu i zbliżenie osady, stany konstrukcji, drogi, stacje, obiekty usługowe, teren, wodę, roślinność i oświetlenie; usunąć widoczne błędy geometrii i kolizje etykiet.
- Utrzymać sprawdzanie formatu oraz testy symulacji w CI; wykonać test przepływu nowej gry, zapisu i wznowienia w obsługiwanych scenariuszach.
- Zmierzyć czas kroku symulacji i FPS na docelowej mapie w Windows, macOS i Linux.

**Odbiór:** tester kończy całą pętlę bez edytora; region mieści się w kadrze i pozostaje czytelny w zbliżeniu; zapis/wczytanie zachowuje rozbudowaną sieć i obiekty; testy CI obejmują kluczowe inwarianty; ręczny przegląd nie pokazuje dróg zawieszonych, martwych narzędzi, błędnych stanów metra ani zatrzymanego HUD-u. Docelowy budżet wydajności jest potwierdzony osobno na każdym systemie.

## Kryteria playtestu pierwszego wycinka

Playtest zaliczony oznacza, że tester bez użycia edytora potrafi:

- zrozumieć, że nie musi podążać za gotową linią;
- zbudować drogę, zajezdnię i własną linię autobusową, a potem poprawnie rozpoznać warunki odblokowania i budowy linii tramwajowej oraz metra;
- rozpoznać, które kohorty wybierają dostępne środki transportu i dlaczego;
- dostrzec pasażerów, przychody i koszty działania transportu oraz usług;
- dobudować usługę w osadzie z niezaspokojonym popytem i zauważyć zmianę pokrycia oraz zdrowia kohort;
- po przyspieszeniu czasu zauważyć autonomiczny rozwój osady oraz wskazać jego związek z dostępnością;
- ocenić czytelność transportu i budowy usług na mapie, w tym schematycznej wizualizacji metra;
- zapisać, wznowić i kontynuować grę.

Testy automatyczne powinny objąć deterministyczność seeda i kohort, bilans podróży, osiągalność grafu, brak popytu na nieosiągalną usługę, monotoniczne reakcje na taryfę/czas, ograniczenia wzrostu i zgodność zapisu/wczytania w trakcie budowy. Test ręczny dodatkowo sprawdza narzędzia, czytelność i stan renderingu.

## Co jest w zakresie, a co pozostaje

**W zakresie prototypu:** autobus, tramwaj i metro z odblokowaniami i wymaganiami tras; model zdrowia oparty na kohortach; popyt, zasięg i pojemność sześciu typów usług; budowanie obiektów usługowych przez gracza; zagregowane finanse transportu i usług; opcjonalne cele postępu; podstawowe narzędzia oraz oprawa regionalna. Te funkcje są już obecne w kodzie, lecz ich balans i odbiór całości nadal wymagają testu.

**Pozostałe zadania:**

1. Przejść ręcznie scenariusz od nowej gry przez drogi, zajezdnię, wszystkie tryby transportu i obiekty usługowe, aż do zapisu, wznowienia i autonomicznego wzrostu.
2. W playteście dostroić progi populacji i środków, koszty budowy i działania, częstotliwości, pojemności, popyt usług oraz tempo zmian zdrowia. Oddzielnie sprawdzić, czy cel 25% dostępności, bilans operatora i cel 95% pokrycia opieką są osiągalne i czytelne.
3. Zaprojektować wizualizację podziemnej trasy metra z czytelnymi stacjami i powierzchnią nad tunelem; obecny schemat powierzchniowy nie jest finalną oprawą metra.
4. Dopracować rozpoznawalność i czytelność obiektów usługowych oraz stanów dróg, torów, stacji i budowy w obu skalach kamery.
5. Zmierzyć klatkaż i czas kroku symulacji na docelowej mapie w Windows, macOS i Linux; do wyniku dołączyć rozmiar mapy i aktywne systemy.

**Poza bieżącym wycinkiem:** mikrosymulacja każdego mieszkańca, realistyczny ruch samochodowy i korki, produkcja oraz łańcuchy dostaw, indywidualne diagnozy, pełne symulacje działania szkół/policji/straży, zaawansowana pogoda i rozbudowany edytor terenu. Zagregowana zachorowalność, leczenie i śmiertelność są już modelowane, ale ich parametry nadal wymagają balansu. Podstawowe pokrycie usługami pozostaje w zakresie; poza nim jest szczegółowa symulacja personelu i kolejek. Funkcjonalny tryb metra, bazowa geometria tunelu, lokalne odsłonięcie terenu i jadący pociąg są już w prototypie; rozbudowany przekrój, oświetlenie tunelu i ręczny odbiór pozostają w wizualnym backlogu.

Premium, AAA-inspirowana stylizacja jest docelowym kierunkiem artystycznym. Bieżący prototyp wymaga najpierw przeglądu dróg, stacji, pojazdów, usług, etykiet, przejść między skalami kamery, terenu i oświetlenia; pełny zestaw modeli, animacji, dźwięku i efektów pozostaje dalszą częścią tego celu, a nie odebranym rezultatem.

## Uzgodnione decyzje projektowe

1. Zostają istniejące drogi lokalne i część regionalnego szkieletu, a kluczowe połączenia między osadami gracz wybiera i finansuje samodzielnie.
2. Drogi, zajezdnia, zakup pojazdów i kursowanie korzystają ze wspólnego budżetu publicznego/operatora. Dochód gospodarstw domowych i obciążenie taryfą są osobnymi wskaźnikami modelowymi.
3. Nowa gra jest otwartym sandboxem bez z góry zadanej linii i wymuszonej kampanii. Opcjonalne cele i kamienie milowe porządkują postęp, ale nie blokują swobodnej gry.
4. Stare zapisy pozostają w trybie legacy; nie importujemy ich automatycznie do nowego regionu.

Powyższe decyzje wynikają z uzgodnień z użytkownikiem i stanowią bazę implementacji. Balans kosztów, popytu i progów wzrostu pozostaje do iteracji w playteście.
