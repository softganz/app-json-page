# app-json-page


## โครงสร้างของ json สำหรับ render
ระดับบนสุดของ JSON จะมี attribute เริ่มต้น 2 ตัวคือ
  - `title` คือ ชื่อสำหรับแสดงบน appBar
  - `type` คือ รูปแบบหลักของการ render (ปัจจุบันมี 3 แบบ: `route` / `widget` / `webview`)

#### Type "route"
เป็นการเปลี่ยนเส้นทางไปยัง named route ของแอปแทนที่จะ render หน้าใน json นี้
- `title` (ไม่บังคับ) จะแสดงบน appBar ชั่วคราวก่อนเปลี่ยนเส้นทาง
- `type` = "route"
- `route` คือชื่อ route ที่ต้องการไป (เช่น `"/about"`)
- การนำทางจริงทำโดย host ผ่าน callback `onRoute` ของ `RenderView` (ไลบรารีไม่รู้จักตาราง route ของแอป) ตัวอย่างใน host:

```dart
RenderView(
  url: 'https://example.com/about.json',
  onRoute: (context, route) => Navigator.of(context).pushNamed(route),
)
```

ตัวอย่าง JSON:
```
{
  "title": "เฝ้าระวังน้ำท่วม",
	"type": "route",
	"route": "/about"
}
```

#### Type "widget"
เป็นการแสดง widget ตามรายการ `show` เรียงตามลำดับ
- `title` (ไม่บังคับ) จะแสดงบน appBar
- `type` = "widget"
- `show` คือ รายการ key ของ widget ที่จะนำมาแสดงตามลำดับ (คั่นด้วย `,`)
- `cameraPhoto` คือ url หลักที่เก็บภาพจากกล้องสำหรับนำมาแสดง
- `cameraLastPhoto` คือ folder สำหรับเก็บภาพล่าสุด
- `cameraRealtimePhoto` คือ folder สำหรับเก็บภาพ realtime ทุก 1 นาที
- `widgets` คือ รายการ widget (Map) ที่ระบุใน `show`
- สำหรับ `type: "widget"` จะมี attribute เพิ่มเติมดังนี้:
  - `type` ของแต่ละ widget มีได้แก่
    - `image` คือการแสดงภาพจาก children หากมีรายการเดียว ให้แสดงภาพเต็มหน้าจอ หากมีมากกว่า 1 ภาพให้แสดงเรียงแนวนอน
    - `cameraSet` คือการแสดงภาพจากกล้อง โดยดึงภาพจาก url ตามรูปแบบ cameraPhoto+cameraLastPhoto+
    - `sizebox` คือชิ้นส่วนว่างสำหรับจัดระยะ

```
{
	"title": "เฝ้าระวังน้ำท่วม",
	"type": "widget",
	"show": "scccrnBanner,cameraHatyai",
	"cameraPhoto": "https://hatyaicityclimate.org/floodphoto/",
	"cameraLastPhoto": "last/",
	"cameraRealtimePhoto": "realtime/",
	"widgets": {
		"scccrnBanner": {
			"type": "image",
			"children": [
				{
					"image": "https://hatyaicityclimate.org/upload/img/banner-scccrn-800w-01.png"
				},
				...
			]
		},
		"cameraHatyai": {
			"type": "cameraSet",
			"title": "Camera set name",
			"children": [
				{
					"title": "Camera title",
					"code": "R01",
					"name": "radartmd"
				},
				...
			]
		},
		...
	}
}
```

## Type webview
webView คือการแสดงเว็บไซต์แบบฝังในแอป (in-app web view) โดยอ่าน `url` และ `title` จากระดับแรก
- `title` (ไม่บังคับ) จะแสดงบน appBar ด้านบน web view
- `type` = "webview"
- `url` คือ url ของเว็บที่ต้องการเปิด
- web view จะขยายเต็มความสูงของพื้นที่แสดงผล

ตัวอย่าง:
```
{
  "title": "เฝ้าระวังน้ำท่วม",
	"type": "webview",
	"url": "https://hatyaicityclimate.org"
}
```
