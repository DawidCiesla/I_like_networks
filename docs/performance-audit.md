# Krótki raport optymalizacji — 2026-10-10

Audyt kodu wykonany z trzema subagentami GPT-6 Luna, reasoning xhigh: rendering,
symulacja i ładowanie. Najważniejsza obserwacja użytkownika: gra jest stabilna
przy nieruchomej kamerze, a problemy występują podczas jej poruszania.
To kieruje pierwszą diagnostykę na pracę zależną od kamery. Poniższe przyczyny
są hipotezami popartymi kodem; nie zmierzono jeszcze CPU/GPU frame time ani FPS.

| Priorytet | Co sprawdzić / zmienić | Uzasadnienie i ograniczenia |
| --- | --- | --- |
| 1 | Zmierzyć i porcjować przebudowy trawy, skał, krzewów i trzcin; następnie cache stałych kafli oraz ponowne użycie MultiMesh. | Ruch kamery wyzwala pełne synchroniczne przebudowy po 92 / 175 / 86 m. Trawa dopuszcza 7800 instancji, krajobraz 3450. Ten trop dotyczy bliskiego planu: renderery pomijają detale powyżej limitów wysokości kamery. Ryzyko zmian: pojawianie się detali z opóźnieniem. |
| 2 | Porównać ten sam ruch z wyłączonym SDFGI, potem cieniami i mgłą wolumetryczną; przygotować presety jakości. | Forward+ włącza jednocześnie SDFGI z 4 kaskadami, SSAO, SSIL, SSR i volumetric fog. GI i cienie są kandydatami także przy oddalonym widoku, gdzie detale nie pracują. Ryzyko: różnice oświetlenia i cieni. |
| 3 | Sprawdzić wewnętrzną rozdzielczość i porównać skalę renderowania 3D 1.0 / 0.75. | Ostatni zrzut miał 4734×2663, projekt deklaruje viewport 1600×900. Zrzut nie dowodzi rozmiaru render targetu; jeśli są zbliżone, liczba pikseli jest ok. 8,8 razy większa. Ryzyko: mniej ostry obraz 3D; UI może zachować rozdzielczość natywną. |
| 4 | Ograniczyć aktualizacje zależne od danych: cache grafu dróg, osobno topologia i koszty podróży, aktualizacje ruchu tranzytu po zmianie snapshotu. | Część pracy działa co klatkę. Snapshot popytu zależy m.in. od zmiennego crowding_ratio; to może powodować ponowne liczenie tras. Projekty miejskie już mają tick 0,2 s — nie trzeba przenosić całej symulacji na nowy zegar. Ryzyko: opóźniona reakcja modelu. |
| 5 | Indeks przestrzenny dróg i parceli dla roślinności; dalsze workerowanie wody/rozmieszczenia roślin i cache per kafel. | Reload roślinności nadal zajmował ok. 6,26 s. Obecnie sprawdza drzewa względem dróg/parceli, a zasoby odtwarza na głównym wątku. To przede wszystkim poprawa ładowania, nie dowód zysku FPS. Ryzyko: synchronizacja wyników i unieważnianie cache. |

Pierwszy eksperyment: ten sam zapis, kamera nieruchoma, następnie powtarzalny
pan, obrót i zoom — osobno w bliskim i dalekim planie. Zebrać CPU/GPU ms,
medianę i p95/p99 czasu klatki oraz czas trzech funkcji `_rebuild`. Porównać
wersję bazową, wyłączone detale oraz wyłączone SDFGI; pozostałe warunki zachować.
Celem dla 60 FPS jest budżet około 16,7 ms i ograniczenie skoków czasu klatki,
nie tylko poprawa średniej FPS. Nie ma podstaw do obiecywania procentowego zysku.

Źródła w checkoutcie:

- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/world/ground_cover_renderer.gd:41`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/world/landscape_detail_renderer.gd:37`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/world/riparian_detail_renderer.gd:37`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/render/world_environment_controller.gd:210`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/main.gd:196`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/core/game_store.gd:612`, `:923`, `:4360`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/transport/road_router.gd:54`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/godot/scripts/world/vegetation_renderer.gd:139`
- `/Users/dawidciesla/Desktop/Repos/GitHub/I_like_networks/docs/region-loading.md`
