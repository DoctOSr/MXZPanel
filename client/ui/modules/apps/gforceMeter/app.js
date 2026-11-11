// GForce Meter — 关键数据精简版: 当前G值 + 昏迷/死亡状态与剩余时间
// 数据源: GForceKO.getState() 的 g (判定用的G值), 保证显示与触发完全一致
// 样式: 透明背景 / 白字 / 文字阴影
angular.module('beamng.apps')
.directive('gforceMeter', [function () {
  return {
    template: '' +
      '<div style="background:transparent !important;color:#fff;padding:8px;' +
      'font-family:\'Overpass Mono\',\'Noto Sans Mono\',monospace;box-sizing:border-box;' +
      'width:100%;height:100%;display:flex;flex-direction:column;justify-content:center;gap:6px;">' +
      '  <div style="display:flex;align-items:baseline;gap:6px;">' +
      '    <span ng-style="{\'color\':gColor}" style="font-size:46px;font-weight:bold;line-height:1;' +
      '      text-shadow:0 0 5px rgba(0,0,0,0.95),0 2px 6px rgba(0,0,0,0.9);">{{g.current.toFixed(2)}}</span>' +
      '    <span style="font-size:15px;text-shadow:0 0 4px rgba(0,0,0,0.9),0 2px 5px rgba(0,0,0,0.85);">G</span>' +
      '  </div>' +
      '  <div style="font-size:16px;font-weight:bold;letter-spacing:1px;' +
      '    text-shadow:0 0 4px rgba(0,0,0,0.95),0 2px 5px rgba(0,0,0,0.9);">' +
      '    {{state.text}}<span ng-if="state.time" style="margin-left:8px;font-size:14px;font-weight:normal;">{{state.time}}</span>' +
      '  </div>' +
      '</div>',
    replace: true,
    restrict: 'EA',
    link: function (scope, element, attrs) {
      scope.g = { current: 0 }
      scope.gColor = '#00ff88'
      scope.state = { text: '正常', time: '' }

      function pollState() {
        if (!bngApi || !bngApi.engineLua) return
        bngApi.engineLua(
          '(GForceKO and GForceKO.getState and jsonEncode(GForceKO.getState())) or "null"',
          function (resp) {
            if (!resp || resp === "null") return
            try {
              var st = JSON.parse(resp)
              var g = st.g || 0

              // 当前 G = GForceKO 判定用的 lastG，保证与触发一致
              scope.g.current = g

              // 颜色阈值 (与 GForceKO 判定阈值一致: 10G 昏迷 / 20G 基米)
              if (g >= 20) scope.gColor = '#ff4040'
              else if (g >= 10) scope.gColor = '#ffcc00'
              else scope.gColor = '#00ff88'

              // 状态 (仅关键数据: 文本 + 剩余时间)
              if (st.isDead) {
                scope.state = {
                  text: '基米!',
                  time: st.timer > 0 ? '剩余 ' + Math.ceil(st.timer) + 's' : ''
                }
              } else if (st.isKnockedOut) {
                scope.state = {
                  text: '昏迷',
                  time: st.timer > 0 ? '剩余 ' + Math.ceil(st.timer) + 's' : ''
                }
              } else {
                scope.state = { text: '正常', time: '' }
              }

              scope.$applyAsync()
            } catch (e) {}
          }
        )
      }

      pollState()
      var pollTimer = setInterval(pollState, 100)

      scope.$on('$destroy', function () {
        if (pollTimer) clearInterval(pollTimer)
      })
    }
  }
}])
