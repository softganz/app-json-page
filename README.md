# app-json-page


## โครงสร้างของ json สำหรับ render
  - title คือ ชื่อสำหรับแสดงบน appBar
  - widget คือ ชิ้นส่วนสำหรับแสดงบนหน้า feed
  - show คือ element ที่จะนำมาแสดงตามลำดับ
  - cameraPhoto คือ url หลักที่เก็บภาพจากกล้องสำหรับนำมาแสดง
  - cameraLastPhoto คือ folder สำหรับเก็บภาพล่าสุด
  - cameraRealtimePhoto คือ folder สำหรับเก็บภาพ realtime ทุก 1 นาที
  - items คือ รายการ element ที่ระบุใน show
  - type คือ รูปแบบการนำมาแสดง
    - image คือการภาพจาก children หากมีรายการเดียว ให้แสดงภาพเต็มหน้าจอ หากมีมากกว่า 1 ภาพให้แสดงเรียงแนวนอน
    - cameraSet คือการแสดงภาพจากกล้อง โดยดึงภาพจาก url ตามรูปแบบ cameraPhoto+cameraLastPhoto+
    - webView คือการแสดงเว็บไซต์แบบฝังในแอป (in-app web view) โดยอ่าน url จากระดับ item (หรือ children รายการแรก) หากมี title จะแสดงบน appBar ด้านบน web view

### รูปแบบข้อมูล JSON

#### Type "route"
การแสดงผลโดยแสดง page จาก route
- `title` (ไม่บังคับ) จะแสดงบน appBar
- `route` คือ route ที่ต้องการแสดง

ตัวอย่าง:
```
{
  "title": "เฝ้าระวังน้ำท่วม",
	"type": "route",
	"route": "/about"
}
```

#### Type "widget"
```
{
	"title": "เฝ้าระวังน้ำท่วม",
	"type": "widget",
	"widget": {
		"show": "scccrnBanner,cameraHatyai",
		"cameraPhoto": "https://hatyaicityclimate.org/floodphoto/",
		"cameraLastPhoto": "last/",
		"cameraRealtimePhoto": "realtime/",
		"items" : {
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
}
```

## Type webView
webView คือการแสดงเว็บไซต์แบบฝังในแอป (in-app web view) โดยอ่าน `url` และ `title` จากระดับแรก
- `title` (ไม่บังคับ) จะแสดงบน appBar ด้านบน web view
- `url` คือ url ของเว็บที่ต้องการเปิด
- web view จะขยายเต็มความสูงของพื้นที่แสดงผล

ตัวอย่าง (อ้างอิงผ่าน `show`):
```
{
  "title": "เฝ้าระวังน้ำท่วม",
	"type": "webView",
	"url": "https://hatyaicityclimate.org"
}
```
