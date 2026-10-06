'use strict';
'require baseclass';
'require fs';

/*
 * 概览页「温度」部件
 *
 * 这个文件不需要注册到任何菜单：LuCI 的概览页（view/status/index.js）会扫描
 * /www/luci-static/resources/view/status/include/ 下的所有 .js，按文件名排序后
 * 逐个 require 并渲染，所以放进这个目录就等于加了一个板块。
 * 目录的 list 权限由 luci-mod-status-index.json 里已有的 ACL 授予。
 *
 * 数据来自 /usr/libexec/xg2010g-temps（见 custom/files-2010/），一次 exec 拿全。
 * 该命令的 exec 权限由 luci-xg2010g-temps.json 授予。
 */

var HELPER = '/usr/libexec/xg2010g-temps';

// 温度分档。用绝对温度而不是「占上限的百分比」来上色：
// 光模块的上限是 70 ℃，但 56 ℃ 对 SFP 来说完全正常，按百分比上色会误报。
function severity(t) {
	if (t >= 90) return 'critical';
	if (t >= 80) return 'high';
	if (t >= 65) return 'warm';
	return 'normal';
}

var COLOR = {
	normal:   '#1d9e75',
	warm:     '#c98a12',
	high:     '#d97706',
	critical: '#dc2626'
};

var BAR_BG = 'rgba(128,128,128,0.25)';

function readTemps() {
	return fs.exec(HELPER, []).then(function(res) {
		if (!res || res.code !== 0 || !res.stdout)
			return { error: res && res.code ? ('exit %d'.format(res.code)) : 'empty' };

		try {
			return JSON.parse(res.stdout);
		} catch (e) {
			return { error: 'bad json' };
		}
	}).catch(function(e) {
		return { error: e && e.name ? e.name : 'rpc error' };
	});
}

return baseclass.extend({
	title: _('温度'),

	load: readTemps,

	render: function(data) {
		if (!data || !Array.isArray(data.sensors) || data.sensors.length === 0) {
			var why = (data && data.error) ? data.error : 'no sensors';
			return E('p', { 'class': 'text-muted' },
				[ _('未能读取温度传感器（%s）。').format(why) ]);
		}

		var table = E('table', { 'class': 'table' });

		data.sensors.forEach(function(s) {
			var t = Number(s.temp);
			var hasMax = (s.max != null && s.max !== 'null');
			var max = hasMax ? Number(s.max) : null;
			var color = COLOR[severity(t)];

			var right = [
				E('span', { 'style': 'font-weight:600;color:%s'.format(color) },
					[ '%.1f °C'.format(t) ])
			];

			if (max) {
				var pct = Math.max(0, Math.min(100, t / max * 100));
				right.push(E('div', {
					'style': 'margin-top:5px;height:6px;border-radius:3px;overflow:hidden;background:%s'.format(BAR_BG),
					'title': _('参考上限 %.0f °C').format(max)
				}, E('div', {
					'style': 'height:100%;width:%.1f%%;background:%s'.format(pct, color)
				})));
			}

			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '50%' }, [
					E('span', {}, [ s.name ]),
					s.detail ? E('br') : null,
					s.detail ? E('span', { 'class': 'text-muted', 'style': 'font-size:90%' }, [ s.detail ]) : null
				]),
				E('td', { 'class': 'td left' }, right)
			]));
		});

		var out = [ table ];

		if (data.missing)
			out.push(E('p', { 'class': 'text-muted', 'style': 'margin-top:8px;font-size:90%' },
				[ _('这些端口没有温度传感器：%s').format(data.missing) ]));

		return E('div', {}, out);
	}
});
