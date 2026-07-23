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
- `routeArgs` (ไม่บังคับ) คือ Map ของ arguments ที่จะส่งไปกับ route (เช่น `{"id": 123}`)
- การนำทางจริงทำโดย host ผ่าน callback `onRoute` ของ `RenderView` (ไลบรารีไม่รู้จักตาราง route ของแอป) ตัวอย่างใน host:

```dart
RenderView(
  url: 'https://example.com/about.json',
  onRoute: (context, route, {routeArgs}) =>
      Navigator.of(context).pushNamed(route, arguments: routeArgs),
)
```

ตัวอย่าง JSON:
```
{
  "title": "เฝ้าระวังน้ำท่วม",
	"type": "route",
	"route": "/about",
	"routeArgs": {"id": 123}
}
```

#### Type "widget"
เป็นการแสดง widget ตามรายการ `show` เรียงตามลำดับ
- `title` (ไม่บังคับ) จะแสดงบน appBar
- `type` = "widget"
- `margin` คือ margin ของหน้า
- `padding` คือ padding ของหน้า
- `show` คือ รายการ key ของ widget ที่จะนำมาแสดงตามลำดับ (คั่นด้วย `,`)
- `cameraPhoto` คือ url หลักที่เก็บภาพจากกล้องสำหรับนำมาแสดง
- `cameraLastPhoto` คือ folder สำหรับเก็บภาพล่าสุด
- `cameraRealtimePhoto` คือ folder สำหรับเก็บภาพ realtime ทุก 1 นาที
- `cameraReloadTime` (ไม่บังคับ) คือช่วงเวลา auto-reload ภาพกล้องในหน่วยวินาที (ใช้กับ `type: cameraSet` ที่มี child ระบุ `name`) ค่าเริ่มต้นคือ `60` หากไม่ระบุหรือระบุค่าไม่ถูกต้อง
- `widgets` คือ รายการ widget (Map) ที่ระบุใน `show`
- สำหรับ `type: "widget"` จะมี attribute เพิ่มเติมดังนี้:
  - `type` ของแต่ละ widget มีได้แก่
    - `image` คือการแสดงภาพจาก children หากมีรายการเดียว ให้แสดงภาพเต็มหน้าจอ หากมีมากกว่า 1 ภาพให้แสดงเรียงแนวนอน
    - `cameraSet` คือการแสดงภาพจากกล้อง โดยดึงภาพจาก url ตามรูปแบบ {cameraPhoto}/{cameraLastPhoto}/{name}.jpg
      - `webViewUrl` (ไม่บังคับ, ระดับ item) คือ template URL สำหรับเปิด in-app-webview เมื่อแตะ child ที่ **ไม่ได้** ระบุ `webViewUrl` ของตัวเอง
        - รองรับ placeholder `{name}` `{code}` `{title}` `{image}` `{url}` `{route}` ซึ่งจะถูกแทนด้วยค่า attribute ของ child นั้น
        - หาก attribute ที่อ้างถึงว่างเปล่า จะข้าม template นี้ (ไม่สร้าง URL ที่ไม่สมบูรณ์)
        - ตัวอย่าง: `"webViewUrl": "https://hatyaicityclimate.org/flood/cam/view?name={name}"` จะแปลงเป็น `...?name=radartmd` สำหรับ child ที่มี `"name": "radartmd"`
      - child ที่มี `webViewUrl` ของตัวเอง จะใช้ของตัวเองตามเดิม (ไม่ถูกแทนค่า)
    - `sizebox` คือชิ้นส่วนว่างสำหรับจัดระยะ

```
{
	"title": "เฝ้าระวังน้ำท่วม",
	"type": "widget",
	"margin": "8",
	"padding": "8",
	"show": "scccrnBanner,cameraHatyai",
	"cameraPhoto": "https://hatyaicityclimate.org/floodphoto/",
	"cameraLastPhoto": "last/",
	"cameraRealtimePhoto": "realtime/",
	"widgets": {
		"scccrnBanner": {
			"type": "image",
			"wrap": true,
			"children": [
				{
					"image": "https://hatyaicityclimate.org/upload/img/banner-scccrn-800w-01.png",
					"url": "", // Url ภายนอก
					"webViewUrl": "", // String?	URL ให้ เปิดใน in-app web view เมื่อแตะรูป
					"route": "", // String?	ชื่อ named route (เช่น "/about") ให้ นำทางในแอป เมื่อแตะรูป
					"routeArgs": "", // Map<String, dynamic>?	arguments ที่ส่งไปกับ route
					"title": "", // String?	ชื่อเรื่อง ใช้เป็น title ของ web view / target ที่เปิด
					"height": "", // double?	ความสูงของรูป (หน่วย pixel)
					"width": "", // double?	ความกว้างของรูป (หน่วย pixel)
					"borderRadius": "", // double?	รัศมีมุมโค้งของรูป (ใช้กับ child นี้โดยเฉพาะ)
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
					"name": "radartmd", // String?	มีในโมเดล แต่ใช้กับ cameraSet เป็นหลัก (ไม่มีผลกับ image)
					"webViewUrl": "",
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
