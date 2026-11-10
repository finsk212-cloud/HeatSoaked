angular.module('beamng.apps')
.directive('heatSoak', [function () {
  return {
    template:
      '<div style="width:100%; height:100%; background:linear-gradient(180deg, #060913 0%, #090e1c 100%); color:#f8fafc; font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif; padding:10px 8px; box-sizing:border-box; overflow-y:auto; user-select:none;">' +

        '<!-- Header -->' +
        '<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; padding-bottom:6px; border-bottom:1px solid rgba(255,255,255,0.08);">' +
          '<div style="font-size:12px; font-weight:900; letter-spacing:0.06em; color:#fff; display:flex; align-items:center; gap:6px;">' +
            '<span style="color:#ef4444;">\u25cf</span> HEATSOAK' +
          '</div>' +
          '<div style="font-size:9px; font-weight:800; color:#94a3b8; font-family:\'JetBrains Mono\',Consolas,monospace;">' +
            'AMB: <span style="color:#fff;">{{ ambientText }}</span> &nbsp; TRK: <span style="color:#fff;">{{ trackText }}</span>' +
          '</div>' +
        '</div>' +

        '<!-- View Selector Tabs -->' +
        '<div style="display:flex; gap:4px; margin-bottom:8px;">' +
          '<button style="flex:1; padding:6px 0; font-size:10px; font-weight:900; letter-spacing:0.08em; text-align:center; border-radius:5px; border:none; cursor:pointer;" ng-style="{background: activeTab === \'TIRES\' ? \'#2563eb\' : \'rgba(255,255,255,0.06)\', color: activeTab === \'TIRES\' ? \'#fff\' : \'#94a3b8\'}" ng-click="activeTab = \'TIRES\'">TIRES</button>' +
          '<button style="flex:1; padding:6px 0; font-size:10px; font-weight:900; letter-spacing:0.08em; text-align:center; border-radius:5px; border:none; cursor:pointer;" ng-style="{background: activeTab === \'ENGINE\' ? \'#2563eb\' : \'rgba(255,255,255,0.06)\', color: activeTab === \'ENGINE\' ? \'#fff\' : \'#94a3b8\'}" ng-click="activeTab = \'ENGINE\'">ENGINE</button>' +
          '<button style="flex:1; padding:6px 0; font-size:10px; font-weight:900; letter-spacing:0.08em; text-align:center; border-radius:5px; border:none; cursor:pointer;" ng-style="{background: activeTab === \'ALL\' ? \'#2563eb\' : \'rgba(255,255,255,0.06)\', color: activeTab === \'ALL\' ? \'#fff\' : \'#94a3b8\'}" ng-click="activeTab = \'ALL\'">ALL</button>' +
        '</div>' +

        '<!-- ================= TAB 1: TIRES ================= -->' +
        '<div ng-if="activeTab === \'TIRES\' || activeTab === \'ALL\'" style="margin-bottom:8px;">' +
          '<div style="position:relative; background:radial-gradient(circle at 50% 50%, rgba(30,41,59,0.45) 0%, rgba(8,12,22,0.98) 100%); border:1px solid rgba(255,255,255,0.1); border-radius:9px; padding:10px 8px;">' +
            '<svg style="position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); width:86px; height:160px; opacity:0.22; pointer-events:none;" viewBox="0 0 100 180" fill="none" stroke="currentColor">' +
              '<path d="M 28 18 Q 50 8 72 18 Q 82 42 78 82 L 80 135 Q 74 168 50 172 Q 26 168 20 135 L 22 82 Q 18 42 28 18 Z" stroke-width="2" stroke="rgba(255,255,255,0.45)"/>' +
              '<path d="M 32 50 L 68 50 L 64 85 L 36 85 Z" stroke-width="1.5" stroke="rgba(255,255,255,0.2)"/>' +
              '<line x1="14" y1="36" x2="86" y2="36" stroke-width="2" stroke="rgba(255,255,255,0.25)"/>' +
              '<line x1="14" y1="142" x2="86" y2="142" stroke-width="2" stroke="rgba(255,255,255,0.25)"/>' +
            '</svg>' +
            '<div ng-repeat="axle in tireAxles" style="display:flex; justify-content:space-between; position:relative; z-index:2; margin-bottom:9px;">' +
              '<div ng-repeat="t in axle.tires" style="width:48.8%; background:rgba(13,20,36,0.96); border:1.5px solid rgba(255,255,255,0.14); border-radius:8px; padding:8px; box-sizing:border-box; box-shadow:0 5px 14px rgba(0,0,0,0.6); overflow:hidden;" ng-style="{borderColor: t.isBlown ? \'#ef4444\' : t.color, boxShadow: t.isBlown ? \'0 0 12px rgba(239,68,68,0.4)\' : \'0 5px 14px rgba(0,0,0,0.6)\'}">' +
                '<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:6px;">' +
                  '<span style="font-size:11.5px; font-weight:900; color:#fff; letter-spacing:0.05em;">{{ t.name }}</span>' +
                  '<span style="font-size:8px; font-weight:900; padding:1.5px 5px; background:rgba(56,189,248,0.18); border:1px solid rgba(56,189,248,0.4); border-radius:3px; color:#38bdf8; letter-spacing:0.04em;">{{ t.compoundName }}</span>' +
                '</div>' +
                '<div style="display:flex; align-items:center; gap:10px; margin-bottom:8px;">' +
                  '<div style="width:32px; height:60px; border-radius:6px; background:#020617; border:2px solid #000; display:flex; overflow:hidden; position:relative; box-shadow:0 3px 8px rgba(0,0,0,0.7); flex-shrink:0;">' +
                    '<div style="flex:1; height:100%; border-right:1px dashed rgba(0,0,0,0.4);" ng-style="{background: t.innerColor}"></div>' +
                    '<div style="flex:1; height:100%; border-right:1px dashed rgba(0,0,0,0.4);" ng-style="{background: t.midColor}"></div>' +
                    '<div style="flex:1; height:100%;" ng-style="{background: t.outerColor}"></div>' +
                    '<div style="position:absolute; top:50%; left:50%; transform:translate(-50%,-50%); width:15px; height:15px; border-radius:50%; border:1.5px solid #000; display:flex; align-items:center; justify-content:center;" ng-style="{background: t.rotorColor, boxShadow: \'0 0 7px \' + t.rotorColor}">' +
                      '<div style="width:4px; height:4px; border-radius:50%; background:#020617;"></div>' +
                    '</div>' +
                  '</div>' +
                  '<div>' +
                    '<div style="font-size:24px; font-weight:900; font-family:\'JetBrains Mono\',Consolas,monospace; line-height:1; margin-bottom:5px; letter-spacing:-0.02em;" ng-style="{color: t.isBlown ? \'#ef4444\' : t.color}">{{ t.tempText }}</div>' +
                    '<div style="display:inline-block; font-size:10px; font-weight:900; font-family:\'JetBrains Mono\',Consolas,monospace; padding:1.5px 6px; border-radius:3px;" ng-style="{color: t.color, background: t.gripBg, border: \'1px solid \' + t.gripBorder}">{{ t.gripText }}</div>' +
                  '</div>' +
                '</div>' +
                '<div style="display:flex; flex-direction:column; gap:3.5px; padding-top:6px; border-top:1px solid rgba(255,255,255,0.1);">' +
                  '<div style="display:flex; justify-content:space-between; align-items:center; font-size:9px; color:#94a3b8; font-weight:800;">' +
                    '<span>WEAR</span>' +
                    '<span style="color:#fff; font-family:\'JetBrains Mono\',monospace; font-weight:900;">{{ t.wearText }}</span>' +
                  '</div>' +
                  '<div style="width:100%; height:6px; background:rgba(255,255,255,0.12); border-radius:3px; overflow:hidden;">' +
                    '<div style="height:100%; border-radius:3px; transition:width 0.3s ease;" ng-style="{width: t.wearFill + \'%\', background: t.wearColor}"></div>' +
                  '</div>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

        '<!-- ================= TAB 2: ENGINE OVERVIEW ================= -->' +
        '<div ng-if="activeTab === \'ENGINE\' || activeTab === \'ALL\'">' +
          '<div style="background:radial-gradient(circle at 50% 50%, rgba(30,41,59,0.3) 0%, rgba(8,12,22,0.98) 100%); border:1px solid rgba(255,255,255,0.1); border-radius:8px; padding:8px 6px; margin-bottom:6px; font-family:\'Overpass\',-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,sans-serif;">' +

            '<!-- Safe Rev Limiter Banner / Toggle -->' +
            '<div style="display:flex; justify-content:space-between; align-items:center; background:rgba(15,23,42,0.9); border:1px solid rgba(255,255,255,0.1); border-radius:6px; padding:6px 10px; margin-bottom:6px;">' +
              '<div>' +
                '<div style="font-size:8px; font-weight:900; color:#94a3b8; letter-spacing:0.06em; text-transform:uppercase;">SAFE REV LIMITER</div>' +
                '<div style="font-size:10px; font-weight:800; font-family:\'Overpass\',sans-serif;" ng-style="{color: safeRevLimit ? (isWarm ? \'#64748b\' : \'#22c55e\') : \'#ef4444\'}">' +
                  '<span ng-if="safeRevLimit && !isWarm">ACTIVE: {{ (safeRpm || 3500) | number:0 }} RPM CAP{{ isDiesel ? " (DIESEL)" : "" }}</span>' +
                  '<span ng-if="safeRevLimit && isWarm">ACTIVE: {{ (safeRpm || 3500) | number:0 }} RPM CAP (WARM)</span>' +
                  '<span ng-if="!safeRevLimit">OFF: FULL REDLINE</span>' +
                '</div>' +
              '</div>' +
              '<button ng-click="toggleSafeRevLimit()" style="border:none; border-radius:4px; padding:5px 12px; font-size:10px; font-weight:900; font-family:\'Overpass\',sans-serif; cursor:pointer; text-transform:uppercase; transition:all 0.15s ease;" ng-style="{background: safeRevLimit ? \'rgba(34,197,94,0.25)\' : \'rgba(239,68,68,0.25)\', border: safeRevLimit ? \'1.5px solid #22c55e\' : \'1.5px solid #ef4444\', color: safeRevLimit ? \'#22c55e\' : \'#ef4444\'}">' +
                '{{ safeRevLimit ? \'SAFE REV: ON\' : \'SAFE REV: OFF\' }}' +
              '</button>' +
            '</div>' +

            '<!-- DUAL MASTER HERO GAUGES: COOLANT & OIL (NO ICONS, OVERPASS FONT) -->' +
            '<div style="display:grid; grid-template-columns:1fr 1fr; gap:6px; margin-bottom:6px;">' +
              '<!-- Coolant Hero Card -->' +
              '<div style="background:linear-gradient(145deg, rgba(15,23,42,0.95) 0%, rgba(8,12,22,0.98) 100%); border:1.5px solid rgba(56,189,248,0.35); border-radius:7px; padding:6px 8px; box-shadow:0 3px 10px rgba(0,0,0,0.4);">' +
                '<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:2px;">' +
                  '<div style="font-size:8.5px; font-weight:900; letter-spacing:0.06em; color:#94a3b8; text-transform:uppercase;">COOLANT</div>' +
                  '<div style="font-size:7px; font-weight:900; padding:1px 4px; border-radius:3px; text-transform:uppercase;" ng-style="{background: coolantStatusBg, color: coolantStatusColor}">{{ coolantStatus }}</div>' +
                '</div>' +
                '<div style="display:flex; align-items:baseline; gap:4px; margin:2px 0;">' +
                  '<div style="font-size:24px; font-weight:900; font-family:\'Overpass\',sans-serif; line-height:1;" ng-style="{color: coolantColor}">{{ coolantText }}</div>' +
                  '<div style="font-size:8px; font-weight:700; color:#64748b;">/ 85-95\u00b0C OPT</div>' +
                '</div>' +
                '<div style="width:100%; height:4px; background:rgba(255,255,255,0.08); border-radius:2px; overflow:hidden; margin-top:2px;">' +
                  '<div style="height:100%; border-radius:2px; transition:width 0.3s ease, background 0.3s ease;" ng-style="{width: coolantBarPct + \'%\', background: coolantColor}"></div>' +
                '</div>' +
              '</div>' +

              '<!-- Oil Hero Card -->' +
              '<div style="background:linear-gradient(145deg, rgba(15,23,42,0.95) 0%, rgba(8,12,22,0.98) 100%); border:1.5px solid rgba(245,158,11,0.35); border-radius:7px; padding:6px 8px; box-shadow:0 3px 10px rgba(0,0,0,0.4);">' +
                '<div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:2px;">' +
                  '<div style="font-size:8.5px; font-weight:900; letter-spacing:0.06em; color:#94a3b8; text-transform:uppercase;">ENGINE OIL</div>' +
                  '<div style="font-size:7px; font-weight:900; padding:1px 4px; border-radius:3px; text-transform:uppercase;" ng-style="{background: oilStatusBg, color: oilStatusColor}">{{ oilStatus }}</div>' +
                '</div>' +
                '<div style="display:flex; align-items:baseline; gap:4px; margin:2px 0;">' +
                  '<div style="font-size:24px; font-weight:900; font-family:\'Overpass\',sans-serif; line-height:1;" ng-style="{color: oilColor}">{{ oilText }}</div>' +
                  '<div style="font-size:8px; font-weight:700; color:#64748b;">/ 90-105\u00b0C OPT</div>' +
                '</div>' +
                '<div style="width:100%; height:4px; background:rgba(255,255,255,0.08); border-radius:2px; overflow:hidden; margin-top:2px;">' +
                  '<div style="height:100%; border-radius:2px; transition:width 0.3s ease, background 0.3s ease;" ng-style="{width: oilBarPct + \'%\', background: oilColor}"></div>' +
                '</div>' +
              '</div>' +
            '</div>' +

            '<!-- CAD ENGINE OVERVIEW (CLEAN THERMAL HEATMAP - NO TEXT FLOATING ON TOP) -->' +
            '<div style="font-size:8px; font-weight:900; color:#94a3b8; letter-spacing:0.08em; text-transform:uppercase; margin-bottom:3px; display:flex; justify-content:space-between;">' +
              '<span>POWERTRAIN ARCHITECTURE</span>' +
              '<span ng-style="{color: badgeColor}">{{ badgeText }}</span>' +
            '</div>' +

            '<svg width="100%" height="256" viewBox="0 0 340 256" fill="none" xmlns="http://www.w3.org/2000/svg" style="background:#030712; border-radius:6px; display:block;">' +
              '<!-- Centerline reference -->' +
              '<line x1="170" y1="0" x2="170" y2="256" stroke="#1e293b" stroke-width="1" stroke-dasharray="3 3" opacity="0.2"/>' +

              '<!-- ================= 1. FRONT COOLING PACK ================= -->' +
              '<!-- FMIC Intercooler (Smaller than Radiator: width 168 vs 192) -->' +
              '<g ng-if="hasTurbo || hasSupercharger">' +
                '<rect x="86" y="6" width="168" height="13" rx="2.5" fill="#0b1329" stroke="#334155" stroke-width="1.2"/>' +
                '<rect x="88" y="8" width="164" height="9" rx="1.5" fill-opacity="0.85" ng-style="{fill: icCoreColor}"/>' +
                '<line x1="104" y1="8" x2="104" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="126" y1="8" x2="126" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="148" y1="8" x2="148" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="170" y1="8" x2="170" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="192" y1="8" x2="192" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="214" y1="8" x2="214" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
                '<line x1="236" y1="8" x2="236" y2="17" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '</g>' +

              '<!-- Radiator (Coolant) - Clean core without text badges -->' +
              '<rect x="74" y="21" width="192" height="15" rx="3" fill="#0b1329" stroke="#334155" stroke-width="1.2"/>' +
              '<rect x="76" y="23" width="188" height="11" rx="2" fill-opacity="0.88" ng-style="{fill: coolantColor}"/>' +
              '<line x1="86" y1="23" x2="86" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="102" y1="23" x2="102" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="118" y1="23" x2="118" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="134" y1="23" x2="134" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="150" y1="23" x2="150" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="166" y1="23" x2="166" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="182" y1="23" x2="182" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="198" y1="23" x2="198" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="214" y1="23" x2="214" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="230" y1="23" x2="230" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +
              '<line x1="246" y1="23" x2="246" y2="34" stroke="#080d1a" stroke-width="1" opacity="0.35"/>' +

              '<!-- Radiator Coolant Hoses connecting cleanly to water pump -->' +
              '<path d="M 92 34 C 92 48 135 52 148 52" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.8" ng-style="{stroke: coolantColor}"/>' +
              '<path d="M 248 34 C 248 48 205 52 192 52" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.8" ng-style="{stroke: coolantColor}"/>' +

              '<!-- ================= 2. CLEANER, SPACIOUS OEM AIRBOX IN FENDER ================= -->' +
              '<!-- Fresh Air Snorkel Scoop -->' +
              '<path d="M 12 12 L 12 22 L 22 22 L 22 12 Z" fill="#1e293b" stroke="#334155" stroke-width="1"/>' +
              '<!-- Main Sealed Airbox Casing -->' +
              '<rect x="4" y="22" width="38" height="30" rx="4" fill="#0f172a" stroke="#334155" stroke-width="1.8"/>' +
              '<rect x="6" y="24" width="34" height="26" rx="3" fill-opacity="0.85" ng-style="{fill: ambientColor}"/>' +
              '<rect x="9" y="27" width="28" height="20" rx="2" fill="none" stroke="#080d1a" stroke-width="1.2" opacity="0.25"/>' +

              '<!-- ================= 3. INLINE-4 ENGINE BLOCK & HEAD (NO TEXT BADGES COVERING CYLINDERS) ================= -->' +
              '<!-- Front Crankshaft Drive Pulley -->' +
              '<circle cx="170" cy="48" r="9" fill="#0f172a" stroke="#334155" stroke-width="2"/>' +
              '<circle cx="170" cy="48" r="4.5" fill="#475569"/>' +

              '<!-- Engine Block Column -->' +
              '<rect x="148" y="52" width="44" height="88" rx="7" fill-opacity="0.9" ng-style="{fill: blockColor}"/>' +
              '<rect x="152" y="56" width="36" height="80" rx="4" fill="none" stroke="#0f172a" stroke-width="2" opacity="0.45"/>' +

              '<!-- 4 Cylinders with Sleeves visible clearly -->' +
              '<circle cx="170" cy="65" r="9" fill="#0f172a"/>' +
              '<circle cx="170" cy="65" r="7.5" fill-opacity="0.8" ng-style="{fill: cylinderHeadColor}"/>' +
              '<circle cx="170" cy="65" r="5" fill="#080d1a" opacity="0.75"/>' +

              '<circle cx="170" cy="85" r="9" fill="#0f172a"/>' +
              '<circle cx="170" cy="85" r="7.5" fill-opacity="0.8" ng-style="{fill: cylinderHeadColor}"/>' +
              '<circle cx="170" cy="85" r="5" fill="#080d1a" opacity="0.75"/>' +

              '<circle cx="170" cy="105" r="9" fill="#0f172a"/>' +
              '<circle cx="170" cy="105" r="7.5" fill-opacity="0.8" ng-style="{fill: cylinderHeadColor}"/>' +
              '<circle cx="170" cy="105" r="5" fill="#080d1a" opacity="0.75"/>' +

              '<circle cx="170" cy="125" r="9" fill="#0f172a"/>' +
              '<circle cx="170" cy="125" r="7.5" fill-opacity="0.8" ng-style="{fill: cylinderHeadColor}"/>' +
              '<circle cx="170" cy="125" r="5" fill="#080d1a" opacity="0.75"/>' +

              '<!-- ================= 4. INTAKE MANIFOLD & RUNNERS ================= -->' +
              '<rect x="190" y="61" width="4" height="8" rx="1" fill="#1e293b"/>' +
              '<rect x="190" y="81" width="4" height="8" rx="1" fill="#1e293b"/>' +
              '<rect x="190" y="101" width="4" height="8" rx="1" fill="#1e293b"/>' +
              '<rect x="190" y="121" width="4" height="8" rx="1" fill="#1e293b"/>' +

              '<path d="M 192 65 L 232 65" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: manifoldHousingColor}"/>' +
              '<path d="M 192 85 L 232 85" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: manifoldHousingColor}"/>' +
              '<path d="M 192 105 L 232 105" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: manifoldHousingColor}"/>' +
              '<path d="M 192 125 L 232 125" stroke-width="5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: manifoldHousingColor}"/>' +

              '<path d="M 232 54 C 248 54 250 64 250 78 L 250 118 C 250 134 246 142 232 142 C 228 142 226 138 226 132 L 226 64 C 226 58 228 54 232 54 Z" fill-opacity="0.9" ng-style="{fill: manifoldHousingColor}"/>' +
              '<path d="M 234 60 L 234 136" stroke="#080d1a" stroke-width="1.8" stroke-linecap="round" opacity="0.35"/>' +
              '<circle cx="236" cy="98" r="4.5" fill="#080d1a" opacity="0.4"/>' +
              '<rect x="238" y="51" width="8" height="6" rx="1" fill="#334155"/>' +

              '<!-- ================= 5A. MODE: TURBOCHARGER (SEPARATED & CURVY) ================= -->' +
              '<g ng-if="hasTurbo">' +
                '<!-- Cold Charge Pipe (Curving smoothly into Throttle Body) -->' +
                '<path d="M 254 12 C 296 12 300 35 292 46 C 284 54 262 54 242 54" stroke-width="5.5" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: iatColor}"/>' +
                '<rect x="250" y="9" width="8" height="6" rx="1" fill="#334155"/>' +

                '<!-- 4 Primary Exhaust Runners into Collector -->' +
                '<path d="M 148 65 C 136 65 128 82 124 95" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 85 C 138 85 130 92 124 97" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 105 C 138 105 130 102 124 100" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 125 C 136 125 128 114 124 102" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +

                '<!-- 4-into-1 Merge Collector -->' +
                '<path d="M 126 92 L 118 95 L 118 101 L 126 104 Z" opacity="0.9" ng-style="{fill: egtColor}"/>' +

                '<!-- TURBINE HOUSING (Hot Side Snail Scroll) -->' +
                '<path d="M 118 91 C 120 80 110 74 100 76 C 92 78 88 86 88 98 C 88 112 96 120 108 120 C 116 120 118 112 118 102 Z" fill-opacity="0.9" ng-style="{fill: turbineColor}"/>' +
                '<path d="M 110 88 C 104 82 96 84 94 96" stroke="#0f172a" stroke-width="1.8" stroke-linecap="round" fill="none" opacity="0.35"/>' +

                '<!-- CHRA Center Bearing Housing -->' +
                '<rect x="76" y="91" width="12" height="18" rx="2" fill="#0f172a"/>' +
                '<rect x="78" y="93" width="8" height="14" rx="1" fill-opacity="0.75" ng-style="{fill: compHousingColor}"/>' +
                '<rect x="74" y="88" width="2.5" height="24" rx="1" fill="#334155"/>' +
                '<rect x="87" y="88" width="2.5" height="24" rx="1" fill="#334155"/>' +

                '<!-- COMPRESSOR HOUSING (Cold Side Snail Volute) -->' +
                '<path d="M 74 82 C 72 70 62 66 52 70 C 44 74 42 84 42 98 C 42 112 50 120 62 120 C 70 120 74 112 74 102 Z" fill-opacity="0.85" ng-style="{fill: compHousingColor}"/>' +
                '<path d="M 64 80 C 56 76 50 80 48 92" stroke="#0f172a" stroke-width="1.8" stroke-linecap="round" fill="none" opacity="0.35"/>' +

                '<!-- Fresh Air Intake Pipe with 26px clear gap to Airbox -->' +
                '<path d="M 36 44 C 44 44 32 74 44 98" stroke-width="8.5" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: ambientColor}"/>' +
                '<rect x="34" y="39" width="7" height="10" rx="1.5" fill="#334155"/>' +
                '<rect x="41" y="94" width="6" height="8" rx="1" fill="#475569"/>' +

                '<!-- Boost Pipe straight to FMIC left tank -->' +
                '<path d="M 64 74 C 64 45 80 13 86 13" stroke-width="5.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: compOutColor}"/>' +
                '<rect x="60" y="70" width="8" height="6" rx="1" fill="#334155"/>' +
                '<rect x="82" y="10" width="8" height="6" rx="1" fill="#334155"/>' +

                '<!-- Exhaust Downpipe & Cat -->' +
                '<path d="M 108 120 C 108 134 116 148 118 160 C 122 170 122 176 122 190" stroke-width="7" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: egtColor}"/>' +
                '<rect x="113" y="174" width="18" height="26" rx="5" fill-opacity="0.9" ng-style="{fill: catalystColor}"/>' +
                '<rect x="116" y="179" width="12" height="16" rx="2" fill="#0f172a" opacity="0.35"/>' +
                '<path d="M 122 200 L 122 210" stroke-width="6.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
              '</g>' +

              '<!-- ================= 5B. MODE: SUPERCHARGER ================= -->' +
              '<g ng-if="!hasTurbo && hasSupercharger">' +
                '<polygon points="98,62 148,64 148,74 100,82" fill="#1e293b" stroke="#334155" stroke-width="1.2" opacity="0.6"/>' +
                '<rect x="84" y="54" width="22" height="36" rx="4" fill="#1e293b" stroke="#475569" stroke-width="1.5"/>' +
                '<circle cx="95" cy="72" r="5" fill="#0f172a" stroke="#334155" stroke-width="1"/>' +

                '<path d="M 82 50 L 90 50 C 96 56 108 64 108 78 C 108 92 98 102 84 102 C 70 102 62 90 64 76 C 66 64 74 54 82 50 Z" fill-opacity="0.9" ng-style="{fill: superchargerHousingColor}"/>' +
                '<path d="M 74 68 C 70 76 72 86 78 92 C 86 96 94 92 96 82" stroke="#0f172a" stroke-width="2" stroke-linecap="round" fill="none" opacity="0.4"/>' +
                '<circle cx="82" cy="78" r="6" fill="#0f172a" opacity="0.65"/>' +
                '<circle cx="82" cy="78" r="2.5" fill="#475569"/>' +

                '<path d="M 170 45 L 95 45 L 95 53 L 170 51 Z" fill="none" stroke="#0f172a" stroke-width="4.5" stroke-linejoin="round"/>' +
                '<path d="M 170 46 L 95 46 L 95 52 L 170 50 Z" fill="none" stroke="#64748b" stroke-width="2" stroke-linejoin="round"/>' +
                '<circle cx="95" cy="48" r="7" fill="#0f172a" stroke="#64748b" stroke-width="1.8"/>' +
                '<circle cx="95" cy="48" r="2.5" fill="#94a3b8"/>' +
                '<rect x="90" y="52" width="10" height="5" rx="1" fill="#334155"/>' +

                '<path d="M 36 44 C 44 44 54 62 62 74" stroke-width="8.5" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: ambientColor}"/>' +
                '<rect x="34" y="39" width="7" height="10" rx="1.5" fill="#334155"/>' +
                '<rect x="58" y="71" width="6" height="7" rx="1" fill="#475569"/>' +

                '<!-- Smooth Boost Discharge Pipe to FMIC left tank -->' +
                '<path d="M 84 56 C 80 42 82 24 86 13" stroke-width="5.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: compOutColor}"/>' +
                '<rect x="80" y="53" width="8" height="6" rx="1" fill="#334155"/>' +
                '<rect x="82" y="10" width="8" height="6" rx="1" fill="#334155"/>' +

                '<path d="M 254 12 C 296 12 300 35 292 46 C 284 54 262 54 242 54" stroke-width="5.5" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: iatColor}"/>' +
                '<rect x="250" y="9" width="8" height="6" rx="1" fill="#334155"/>' +

                '<path d="M 148 65 C 132 65 124 88 124 140" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 85 C 134 85 126 102 126 140" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 105 C 136 105 128 116 127 140" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 125 C 136 125 129 130 128 140" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 130 136 L 122 140 L 122 146 L 130 150 Z" opacity="0.9" ng-style="{fill: egtColor}"/>' +
                '<path d="M 125 146 C 125 158 123 165 122 174" stroke-width="6.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<rect x="113" y="174" width="18" height="26" rx="5" fill-opacity="0.9" ng-style="{fill: catalystColor}"/>' +
                '<rect x="116" y="179" width="12" height="16" rx="2" fill="#0f172a" opacity="0.35"/>' +
                '<path d="M 122 200 L 122 210" stroke-width="6.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
              '</g>' +

              '<!-- ================= 5C. MODE: NA (NATURALLY ASPIRATED) ================= -->' +
              '<g ng-if="!hasTurbo && !hasSupercharger">' +
                '<path d="M 40 36 C 88 34 148 34 205 36 C 225 37 242 41 242 48" stroke-width="8.5" stroke-linecap="round" fill="none" opacity="0.9" ng-style="{stroke: ambientColor}"/>' +
                '<rect x="36" y="31" width="7" height="10" rx="1.5" fill="#334155"/>' +

                '<path d="M 148 65 C 114 65 102 85 104 128" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 85 C 120 85 106 100 106 128" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 105 C 126 105 108 112 108 128" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<path d="M 148 125 C 132 125 112 122 110 128" stroke-width="4.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +

                '<path d="M 102 126 L 112 126 L 110 136 L 104 136 Z" opacity="0.9" ng-style="{fill: egtColor}"/>' +
                '<path d="M 107 136 C 107 148 107 160 107 174" stroke-width="6.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
                '<rect x="98" y="174" width="18" height="26" rx="5" fill-opacity="0.9" ng-style="{fill: catalystColor}"/>' +
                '<rect x="101" y="179" width="12" height="16" rx="2" fill="#0f172a" opacity="0.35"/>' +
                '<path d="M 107 200 L 107 212" stroke-width="6.5" stroke-linecap="round" fill="none" opacity="0.85" ng-style="{stroke: egtColor}"/>' +
              '</g>' +

              '<!-- ================= 6. TRANSMISSION ================= -->' +
              '<g id="transmission-group">' +
                '<path d="M 148 140 L 144 148 C 144 153 147 156 150 156 L 190 156 C 193 156 196 153 196 148 L 192 140 Z" fill-opacity="0.85" ng-style="{fill: gearboxColor}"/>' +
                '<path d="M 150 156 L 153 188 C 153 191 155 192 157 192 L 183 192 C 185 191 187 188 190 156 Z" fill-opacity="0.85" ng-style="{fill: gearboxColor}"/>' +
                '<line x1="154" y1="165" x2="186" y2="165" stroke="#0f172a" stroke-width="1.8" opacity="0.35"/>' +
                '<line x1="155" y1="174" x2="185" y2="174" stroke="#0f172a" stroke-width="1.8" opacity="0.35"/>' +
                '<path d="M 166 192 L 166 220 L 174 220 L 174 192 Z" fill="#1e293b"/>' +
              '</g>' +
            '</svg>' +
          '</div>' +

          '<!-- ALL COMPONENT TEMPERATURES (ORGANIZED DASHBOARD, OVERPASS FONT) -->' +
          '<div style="font-size:8px; font-weight:900; color:#94a3b8; letter-spacing:0.08em; text-transform:uppercase; margin:6px 0 3px 0; display:flex; justify-content:space-between; font-family:\'Overpass\',sans-serif;">' +
            '<span>ALL COMPONENT TEMPERATURES</span>' +
            '<span style="color:#64748b;">LIVE FLIR SENSORS</span>' +
          '</div>' +

          '<div style="display:grid; grid-template-columns:repeat(4, 1fr); gap:4px; margin-bottom:6px; font-family:\'Overpass\',sans-serif;">' +
            '<!-- Row 1: Engine Core -->' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">CYL HEAD</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: cylinderHeadColor}">{{ headText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">ENG BLOCK</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: blockColor}">{{ blockText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">ROD BRGS</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: rodBearingsColor}">{{ rodText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">CYL WALL</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: wallColor}">{{ wallText }}</div>' +
            '</div>' +

            '<!-- Row 2: Intake & Bay -->' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">INTAKE AIR</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: iatColor}">{{ iatText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">INTERCOOLER</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: icCoreColor}">{{ icText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">MANIFOLD</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: manifoldHousingColor}">{{ manifoldText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">ENGINE BAY</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: bayColor}">{{ bayText }}</div>' +
            '</div>' +

            '<!-- Row 3: Exhaust & FI -->' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">EXHAUST</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: egtColor}">{{ egtText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">{{ forcedLabel }}</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: forcedColor}">{{ forcedText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">CATALYTIC</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: catalystColor}">{{ catText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">BOOST OUT</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: compOutColor}">{{ boostOutText }}</div>' +
            '</div>' +

            '<!-- Row 4: Drivetrain & Ambient -->' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">GEARBOX</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: gearboxColor}">{{ gbxText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">DIFF OIL</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: diffColor}">{{ diffText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">AMBIENT</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: ambientColor}">{{ ambientText }}</div>' +
            '</div>' +
            '<div style="background:#0a0f1d; border:1px solid rgba(255,255,255,0.07); border-radius:5px; padding:4px 2px; text-align:center;">' +
              '<div style="font-size:7px; font-weight:800; color:#64748b; letter-spacing:0.04em;">TRACK SURF</div>' +
              '<div style="font-size:11.5px; font-weight:900; margin-top:1px;" ng-style="{color: ambientColor}">{{ trackText }}</div>' +
            '</div>' +
          '</div>' +
        '</div>' +

        '<!-- Damage Alerts -->' +
        '<div ng-if="damageAlerts.length" style="background:rgba(239,68,68,0.16); border:1.5px solid rgba(239,68,68,0.5); border-radius:6px; padding:6px 8px; margin-top:5px;">' +
          '<div style="font-size:8.5px; font-weight:900; color:#fca5a5; margin-bottom:3px; display:flex; justify-content:space-between;">' +
            '<span>\u26a0\ufe0f DAMAGE</span>' +
            '<span>{{ damageAlerts.length }} ACTIVE</span>' +
          '</div>' +
          '<div ng-repeat="d in damageAlerts" style="display:flex; justify-content:space-between; font-size:8px; color:#f87171; margin-bottom:1px;">' +
            '<span>{{ d.name }}</span>' +
            '<span style="font-weight:900;">{{ d.value }}%</span>' +
          '</div>' +
        '</div>' +
      '</div>',

    replace: true,
    restrict: 'EA',
    link: function ($scope, element, attrs) {
      $scope.activeTab = 'ENGINE';
      $scope.hasAnyData = false;
      $scope.hasTurbo = false;
      $scope.hasSupercharger = false;

      $scope.ambientText = '--';
      $scope.trackText = '--';
      $scope.coolantText = '--';
      $scope.oilText = '--';
      $scope.headText = '--';
      $scope.blockText = '--';
      $scope.egtText = '--';
      $scope.badgeText = 'POWERTRAIN CAD';
      $scope.badgeColor = '#38bdf8';
      $scope.safeRevLimit = true;
      $scope.isWarm = false;
      $scope.isDiesel = false;
      $scope.safeRpm = 3500;
      $scope.hasAnyData = false;
      $scope.hasTurbo = false;
      $scope.hasSupercharger = false;

      $scope.ambientText = '--';
      $scope.trackText = '--';

      // Gradual Continuous RGB Color Interpolation (FLIR Thermal Style)
      function interpolateGradualColor(temp, minT, optT, warnT, critT) {
        if (temp == null || isNaN(temp)) return '#94a3b8';

        if (critT === undefined) {
          critT = warnT;
          warnT = optT;
          optT = minT + (warnT - minT) * 0.5;
        }

        var cCold = [56, 189, 248];   // Ice Blue (#38bdf8)
        var cOpt  = [34, 197, 94];    // Racing Green (#22c55e)
        var cWarm = [234, 179, 8];    // Warm Gold/Yellow (#eab308)
        var cWarn = [249, 115, 22];   // Orange (#f97316)
        var cCrit = [239, 68, 68];    // Alert Red (#ef4444)
        var cExtr = [185, 28, 28];    // Deep Crimson (#b91c1c)

        function lerp(c1, c2, f) {
          f = Math.max(0, Math.min(1, f));
          var r = Math.round(c1[0] + (c2[0] - c1[0]) * f);
          var g = Math.round(c1[1] + (c2[1] - c1[1]) * f);
          var b = Math.round(c1[2] + (c2[2] - c1[2]) * f);
          return 'rgb(' + r + ',' + g + ',' + b + ')';
        }

        var midWarn = (warnT + critT) * 0.5;

        if (temp <= minT) {
          return 'rgb(' + cCold[0] + ',' + cCold[1] + ',' + cCold[2] + ')';
        } else if (temp < optT) {
          return lerp(cCold, cOpt, (temp - minT) / (optT - minT));
        } else if (temp < warnT) {
          return lerp(cOpt, cWarm, (temp - optT) / (warnT - optT));
        } else if (temp < midWarn) {
          return lerp(cWarm, cWarn, (temp - warnT) / (midWarn - warnT));
        } else if (temp < critT) {
          return lerp(cWarn, cCrit, (temp - midWarn) / (critT - midWarn));
        } else {
          return lerp(cCrit, cExtr, Math.min((temp - critT) / 25.0, 1.0));
        }
      }

      var colorForTemp = interpolateGradualColor;

      function formatTemp(temp) {
        if (temp == null || isNaN(temp)) return '--';
        return Math.round(temp) + '\u00b0C';
      }

      function makeGauge(name, val, minT, optT, warnT, critT, boostTag) {
        var num = val != null && !isNaN(val) ? val : null;
        var text = num != null ? Math.round(num) + '\u00b0C' : '--';
        var col = interpolateGradualColor(num, minT, optT, warnT, critT);
        var norm = num != null ? Math.max(0, Math.min(1, (num - (minT - 15)) / (critT - (minT - 15) + 10))) : 0.4;
        var fillPct = Math.round(norm * 100);
        var status = 'NORM';
        var statusColor = '#22c55e';
        var statusBg = 'rgba(34,197,94,0.15)';
        var statusBorder = 'rgba(34,197,94,0.35)';

        if (num == null) {
          status = '--'; statusColor = '#64748b'; statusBg = 'transparent'; statusBorder = 'transparent';
        } else if (boostTag && num > warnT) {
          status = 'BOOST'; statusColor = col; statusBg = 'rgba(249,115,22,0.15)'; statusBorder = 'rgba(249,115,22,0.35)';
        } else if (num < minT) {
          status = 'COLD'; statusColor = '#38bdf8'; statusBg = 'rgba(56,189,248,0.15)'; statusBorder = 'rgba(56,189,248,0.35)';
        } else if (num >= critT) {
          status = 'HOT'; statusColor = '#ef4444'; statusBg = 'rgba(239,68,68,0.15)'; statusBorder = 'rgba(239,68,68,0.35)';
        } else if (num >= warnT) {
          status = 'WARM'; statusColor = '#f59e0b'; statusBg = 'rgba(245,158,11,0.15)'; statusBorder = 'rgba(245,158,11,0.35)';
        }

        return {
          name: name,
          val: num,
          text: text,
          color: col,
          fillPct: fillPct,
          status: status,
          statusColor: statusColor,
          statusBg: statusBg,
          statusBorder: statusBorder
        };
      }

      $scope.updateTires = function (tiresData) {
        if (!tiresData || !tiresData.length) return;
        var axlesMap = {};
        for (var i = 0; i < tiresData.length; i++) {
          var td = tiresData[i];
          var axId = td.axle || (td.name && td.name.charAt(0) === 'F' ? 'FRONT' : 'REAR');
          if (!axlesMap[axId]) axlesMap[axId] = [];

          var tCol = interpolateGradualColor(td.treadT, 50, 85, 105, 130);
          var inCol = interpolateGradualColor(td.innerT != null ? td.innerT : td.treadT, 50, 85, 105, 130);
          var midCol = interpolateGradualColor(td.midT != null ? td.midT : td.treadT, 50, 85, 105, 130);
          var outCol = interpolateGradualColor(td.outerT != null ? td.outerT : td.treadT, 50, 85, 105, 130);
          var rotCol = interpolateGradualColor(td.brakeTemp, 100, 300, 550, 800);

          var wPct = td.wearPercent != null ? Math.max(0, Math.min(100, td.wearPercent)) : 0;
          var wCol = wPct > 50 ? '#ef4444' : (wPct > 25 ? '#f59e0b' : '#22c55e');

          var cName = (td.compoundName || td.compound || 'STD').toUpperCase();
          if (cName.indexOf('RACE') !== -1) cName = 'RACE SLICK';
          else if (cName.indexOf('SPORT') !== -1) cName = 'SPORT';
          else if (cName.indexOf('DRAG') !== -1) cName = 'DRAG';
          else if (cName.indexOf('OFFROAD') !== -1) cName = 'OFFROAD';

          var gBg = 'rgba(34,197,94,0.15)';
          var gBorder = 'rgba(34,197,94,0.35)';
          if (td.treadT >= 105) {
            gBg = 'rgba(239,68,68,0.15)'; gBorder = 'rgba(239,68,68,0.35)';
          } else if (td.treadT >= 95) {
            gBg = 'rgba(245,158,11,0.15)'; gBorder = 'rgba(245,158,11,0.35)';
          } else if (td.treadT < 60) {
            gBg = 'rgba(56,189,248,0.15)'; gBorder = 'rgba(56,189,248,0.35)';
          }

          axlesMap[axId].push({
            name: td.name || ('T' + (i + 1)),
            compoundName: cName,
            tempText: formatTemp(td.treadT),
            color: tCol,
            innerColor: inCol,
            midColor: midCol,
            outerColor: outCol,
            gripText: td.gripPercent != null ? Math.round(td.gripPercent) + '% GRIP' : '--',
            gripBg: gBg,
            gripBorder: gBorder,
            wearText: wPct.toFixed(1) + '%',
            wearFill: Math.min(100, Math.max(2, wPct)),
            wearColor: wCol,
            rotorColor: rotCol,
            isBlown: !!td.blown
          });
        }
        $scope.tireAxles = [];
        var order = ['FRONT', 'REAR'];
        for (var j = 0; j < order.length; j++) {
          if (axlesMap[order[j]]) {
            $scope.tireAxles.push({ name: order[j], tires: axlesMap[order[j]] });
          }
        }
        for (var k in axlesMap) {
          if (order.indexOf(k) === -1) {
            $scope.tireAxles.push({ name: k, tires: axlesMap[k] });
          }
        }
      };

      $scope.toggleSafeRevLimit = function () {
        $scope.safeRevLimit = !$scope.safeRevLimit;
        var cmd = "if heatsoak and heatsoak.toggleSafeRevLimit then heatsoak.toggleSafeRevLimit() elseif extensions.heatsoak and extensions.heatsoak.toggleSafeRevLimit then extensions.heatsoak.toggleSafeRevLimit() end";
        if (window.bngApi && window.bngApi.activeObjectLua) {
          window.bngApi.activeObjectLua(cmd);
        } else if (typeof bngApi !== 'undefined' && bngApi.activeObjectLua) {
          bngApi.activeObjectLua(cmd);
        } else if (window.beamNG && window.beamNG.sendActiveObjectLua) {
          window.beamNG.sendActiveObjectLua(cmd);
        }
        $scope.$evalAsync();
      };

      $scope.updateEngine = function (d) {
        $scope.coolant = d.coolant;
        $scope.oil = d.oil;
        $scope.cylinderHead = d.cylinderHead;
        $scope.rodBearings = d.rodBearings;
        $scope.block = d.block != null ? d.block : d.coolant;
        $scope.wall = d.wall != null ? d.wall : d.cylinderHead;
        $scope.egt = d.egt;
        $scope.turbine = d.turbineHousing;
        $scope.compOut = d.compressorOut || d.superchargerOut;
        $scope.compHousing = d.compressorHousing != null ? d.compressorHousing : (d.icCore != null ? d.icCore : 35);
        $scope.superchargerHousing = d.superchargerHousing;
        $scope.manifoldHousing = d.manifoldHousing != null ? d.manifoldHousing : (d.cylinderHead ? d.cylinderHead * 0.72 : 45);
        $scope.iat = d.iat;
        $scope.icCore = d.icCore;
        $scope.bayAir = d.engineBayAir;
        $scope.gearbox = d.gearboxOil;
        $scope.diff = d.diffOil;
        $scope.catalyst = d.catalyst;

        $scope.hasTurbo = !!(d.hasTurbo || d.turbineHousing != null);
        $scope.hasSupercharger = !!(d.hasSupercharger || (!d.hasTurbo && d.superchargerHousing != null));

        // Gradual Thermal Heatmap Colors (FLIR continuous RGB interpolation)
        $scope.ambientColor = interpolateGradualColor(d.ambient, 10, 22, 35, 48);
        $scope.compOutColor = interpolateGradualColor($scope.compOut, 35, 65, 100, 130);
        $scope.iatColor = interpolateGradualColor(d.iat, 20, 35, 55, 75);
        $scope.icCoreColor = interpolateGradualColor(d.icCore != null ? d.icCore : d.iat, 20, 35, 55, 75);
        $scope.bayColor = interpolateGradualColor($scope.bayAir, 25, 45, 65, 85);

        $scope.coolantColor = interpolateGradualColor(d.coolant, 60, 85, 105, 120);
        $scope.oilColor = interpolateGradualColor(d.oil, 65, 95, 115, 135);
        $scope.blockColor = interpolateGradualColor($scope.block, 60, 85, 105, 120);
        $scope.cylinderHeadColor = interpolateGradualColor(d.cylinderHead, 65, 95, 125, 145);
        $scope.wallColor = interpolateGradualColor($scope.wall, 65, 95, 125, 145);
        $scope.rodBearingsColor = interpolateGradualColor(d.rodBearings, 75, 105, 125, 145);
        $scope.manifoldHousingColor = interpolateGradualColor($scope.manifoldHousing, 30, 65, 88, 105);
        $scope.egtColor = interpolateGradualColor(d.egt, 300, 550, 750, 950);
        $scope.turbineColor = interpolateGradualColor(d.turbineHousing, 250, 500, 700, 880);
        $scope.compHousingColor = interpolateGradualColor($scope.compHousing, 25, 50, 80, 105);
        $scope.superchargerHousingColor = interpolateGradualColor($scope.superchargerHousing, 25, 52, 82, 108);
        $scope.catalystColor = interpolateGradualColor(d.catalyst, 300, 600, 800, 980);
        $scope.gearboxColor = interpolateGradualColor(d.gearboxOil, 40, 75, 110, 130);
        $scope.diffColor = interpolateGradualColor(d.diffOil, 40, 70, 105, 125);

        // Coolant Hero Status & Bar
        if (d.coolant != null) {
          $scope.coolantText = Math.round(d.coolant) + '\u00b0C';
          $scope.coolantBarPct = Math.min(100, Math.max(8, Math.round(((d.coolant - 0) / 125) * 100)));
          if (d.coolant < 65) {
            $scope.coolantStatus = 'COLD';
            $scope.coolantStatusColor = '#38bdf8';
            $scope.coolantStatusBg = 'rgba(56,189,248,0.18)';
          } else if (d.coolant <= 100) {
            $scope.coolantStatus = 'OPTIMAL';
            $scope.coolantStatusColor = '#22c55e';
            $scope.coolantStatusBg = 'rgba(34,197,94,0.18)';
          } else if (d.coolant <= 112) {
            $scope.coolantStatus = 'WARM';
            $scope.coolantStatusColor = '#f59e0b';
            $scope.coolantStatusBg = 'rgba(245,158,11,0.18)';
          } else {
            $scope.coolantStatus = 'HOT';
            $scope.coolantStatusColor = '#ef4444';
            $scope.coolantStatusBg = 'rgba(239,68,68,0.18)';
          }
        } else {
          $scope.coolantText = '--';
          $scope.coolantStatus = 'OFFLINE';
          $scope.coolantStatusColor = '#94a3b8';
          $scope.coolantStatusBg = 'rgba(255,255,255,0.06)';
          $scope.coolantBarPct = 8;
        }

        // Oil Hero Status & Bar
        if (d.oil != null) {
          $scope.oilText = Math.round(d.oil) + '\u00b0C';
          $scope.oilBarPct = Math.min(100, Math.max(8, Math.round(((d.oil - 0) / 140) * 100)));
          if (d.oil < 65) {
            $scope.oilStatus = 'COLD';
            $scope.oilStatusColor = '#38bdf8';
            $scope.oilStatusBg = 'rgba(56,189,248,0.18)';
          } else if (d.oil <= 115) {
            $scope.oilStatus = 'OPTIMAL';
            $scope.oilStatusColor = '#22c55e';
            $scope.oilStatusBg = 'rgba(34,197,94,0.18)';
          } else if (d.oil <= 130) {
            $scope.oilStatus = 'WARM';
            $scope.oilStatusColor = '#f59e0b';
            $scope.oilStatusBg = 'rgba(245,158,11,0.18)';
          } else {
            $scope.oilStatus = 'HOT';
            $scope.oilStatusColor = '#ef4444';
            $scope.oilStatusBg = 'rgba(239,68,68,0.18)';
          }
        } else {
          $scope.oilText = '--';
          $scope.oilStatus = 'OFFLINE';
          $scope.oilStatusColor = '#94a3b8';
          $scope.oilStatusBg = 'rgba(255,255,255,0.06)';
          $scope.oilBarPct = 8;
        }

        // All Component Telemetry Texts
        $scope.headText = d.cylinderHead != null ? Math.round(d.cylinderHead) + '\u00b0C' : ($scope.coolantText);
        $scope.blockText = $scope.block != null ? Math.round($scope.block) + '\u00b0C' : ($scope.coolantText);
        $scope.rodText = d.rodBearings != null ? Math.round(d.rodBearings) + '\u00b0C' : ($scope.oilText);
        $scope.wallText = $scope.wall != null ? Math.round($scope.wall) + '\u00b0C' : ($scope.headText);

        $scope.iatText = d.iat != null ? Math.round(d.iat) + '\u00b0C' : ($scope.ambientText || '--');
        $scope.icText = d.icCore != null ? Math.round(d.icCore) + '\u00b0C' : ($scope.iatText);
        $scope.manifoldText = $scope.manifoldHousing != null ? Math.round($scope.manifoldHousing) + '\u00b0C' : '--';
        $scope.bayText = d.engineBayAir != null ? Math.round(d.engineBayAir) + '\u00b0C' : '--';

        $scope.egtText = d.egt != null ? Math.round(d.egt) + '\u00b0C' : '--';
        if ($scope.hasTurbo) {
          $scope.forcedLabel = 'TURBINE';
          $scope.forcedText = d.turbineHousing != null ? Math.round(d.turbineHousing) + '\u00b0C' : '--';
          $scope.forcedColor = $scope.turbineColor;
        } else if ($scope.hasSupercharger) {
          $scope.forcedLabel = 'SUPERCHG';
          $scope.forcedText = d.superchargerHousing != null ? Math.round(d.superchargerHousing) + '\u00b0C' : '--';
          $scope.forcedColor = $scope.superchargerHousingColor;
        } else {
          $scope.forcedLabel = 'EXH HEADER';
          $scope.forcedText = d.egt != null ? Math.round(d.egt * 0.78) + '\u00b0C' : '--';
          $scope.forcedColor = $scope.egtColor;
        }

        $scope.catText = d.catalyst != null ? Math.round(d.catalyst) + '\u00b0C' : '--';
        $scope.boostOutText = $scope.compOut != null ? Math.round($scope.compOut) + '\u00b0C' : '--';
        $scope.gbxText = d.gearboxOil != null ? Math.round(d.gearboxOil) + '\u00b0C' : '--';
        $scope.diffText = d.diffOil != null ? Math.round(d.diffOil) + '\u00b0C' : '--';

        $scope.badgeText = $scope.hasTurbo ? 'TURBO CAD' : ($scope.hasSupercharger ? 'SUPERCHARGED CAD' : 'NA CAD');
        $scope.badgeColor = $scope.hasTurbo ? '#38bdf8' : ($scope.hasSupercharger ? '#f59e0b' : '#22c55e');

        // Damage alerts
        var alerts = [];
        if (d.damage) {
          for (var k in d.damage) {
            var v = d.damage[k];
            if (v && v > 0.01) {
              var label = k;
              if (k === 'headGasket') label = 'Head Gasket';
              else if (k === 'pistonRings') label = 'Piston Rings';
              else if (k === 'rodBearings') label = 'Rod Bearings';
              else if (k === 'turboBearings') label = 'Turbo Bearings';
              else if (k === 'radiatorLeak') label = 'Radiator Leak';
              alerts.push({ name: label, value: (v * 100).toFixed(1) });
            }
          }
        }
        $scope.damageAlerts = alerts;
      };

      // Set initial neutral states
      $scope.updateEngine({});

      function processData(data) {
        if (!data) return;
        $scope.hasAnyData = true;
        $scope.safeRevLimit = data.safeRevLimit != null ? data.safeRevLimit : true;
        $scope.isWarm = !!data.isWarm;
        $scope.isDiesel = !!data.isDiesel;
        $scope.safeRpm = data.safeRpm || 3500;

        if (data.ambient != null) {
          $scope.ambientText = Math.round(data.ambient) + '\u00b0C';
        }
        if (data.surface != null) {
          $scope.trackText = Math.round(data.surface) + '\u00b0C';
        } else if (data.trackTemp != null) {
          $scope.trackText = Math.round(data.trackTemp) + '\u00b0C';
        }

        if (data.tires) {
          $scope.updateTires(data.tires);
        }
        $scope.updateEngine(data);
        $scope.$evalAsync();
      }

      $scope.$on('HeatSoakData', function (event, data) {
        processData(data);
      });

      $scope.$on('HeatSoakUpdate', function (event, data) {
        processData(data);
      });

      element.on('$destroy', function () {});
    }
  };
}]);
