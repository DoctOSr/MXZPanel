/* ============================================================================
 *  Fuk 抓捕状态 — UI App (BeamNG 现代 AngularJS App 规范)
 *
 *  数据通道:
 *    客户端扩展 mxz.lua -> guihooks.trigger("fukStatus", payload)
 *    本 App             -> scope.$on("fukStatus", function(event, data) ...)
 *  首次加载时也通过 bngApi.engineLua 轮询一次 extensions.mxz.getFukAppState()
 *  作为初始值(扩展刚加载/UI 后加载时事件可能错过)。
 *
 *  payload: {
 *    gameState = 0/1/2 (空闲/倒计时/追杀),
 *    countdown = 追杀剩余秒,
 *    ffState   = "idle"/"cooldown"/"active",
 *    ffRemain  = 力场当前相位剩余秒
 *  }
 *  样式要求: 纯白字、无黑色透明底、字体带阴影 (见 app.css)
 * ==========================================================================*/
angular.module('beamng.apps').directive('fukStatus', [function () {

  'use strict';

  var TEMPLATE =
    '<div class="fuk-status">' +
      '<div class="fuk-line" ng-show="s.gameState > 0">抓捕时间 <span class="fuk-num">{{s.chaseText}}</span></div>' +
      '<div class="fuk-line" ng-show="s.gameState > 0">力场状态 <span class="fuk-num">{{s.ffText}}</span></div>' +
    '</div>';

  return {
    template: TEMPLATE,
    replace: true,
    restrict: 'EA',
    link: function (scope) {
      // 注入样式表 (与 SignalLights/gforceMeter 相同的做法)
      if (!document.getElementById('fuk-status-css')) {
        var link = document.createElement('link');
        link.id = 'fuk-status-css';
        link.rel = 'stylesheet';
        link.type = 'text/css';
        link.href = '/ui/modules/apps/fukStatus/app.css';
        document.head.appendChild(link);
      }

      scope.s = { gameState: 0, chaseText: '', ffText: '' };

      function fmt(sec) {
        sec = Math.max(0, Math.floor(sec || 0));
        var m = Math.floor(sec / 60);
        var s = sec % 60;
        return m + ':' + (s < 10 ? '0' : '') + s;
      }

      function update(data) {
        var d = data || {};
        scope.s.gameState = d.gameState || 0;
        if (d.gameState === 1) {
          scope.s.chaseText = '倒计时 ' + Math.floor(d.countdown || 0) + 's';
        } else if (d.gameState === 2) {
          scope.s.chaseText = fmt(d.countdown);
        } else {
          scope.s.chaseText = '';
        }
        if (d.ffState === 'active') {
          scope.s.ffText = '激活中 ' + Math.floor(d.ffRemain || 0) + 's';
        } else if (d.ffState === 'cooldown') {
          scope.s.ffText = '冷却中 ' + Math.floor(d.ffRemain || 0) + 's';
        } else if (d.gameState === 2) {
          scope.s.ffText = '未开启';
        } else {
          scope.s.ffText = '';
        }
        scope.$applyAsync();
      }

      scope.$on('fukStatus', function (event, data) { update(data); });

      // 初始值: 轮询一次扩展状态 (扩展暴露了 getFukAppState)
      if (bngApi && bngApi.engineLua) {
        bngApi.engineLua(
          '(extensions.mxz and extensions.mxz.getFukAppState and jsonEncode(extensions.mxz.getFukAppState())) or "null"',
          function (resp) {
            if (resp && resp !== 'null') {
              try { update(JSON.parse(resp)); } catch (e) {}
            }
          }
        );
      }
    }
  }
}])
