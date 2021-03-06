import tornado.gen
import tornado.web

from common.web import requestsManager
from common.sentry import sentry
from helpers.locationHelper import getCountry

MODULE_NAME = "direct_download"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /d/
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self, fuck, bid):
		if fuck != 'd':
			bid = fuck
		try:
			noVideo = bid.endswith("n")
			if noVideo:
				bid = bid[:-1]
			bid = int(bid)

			self.set_status(302, "Moved Temporarily")
			if getCountry(self.request.headers['X-Real-Ip']) == "CN":
				url = f"https://txy1.sayobot.cn/beatmaps/download/{'novideo' if noVideo else 'full'}/{bid}"
			else:
				url = f"https://bloodcat.com/osu/m/{bid}"
			self.add_header("Location", url)
			self.add_header("Cache-Control", "no-cache")
			self.add_header("Pragma", "no-cache")
		except ValueError:
			self.set_status(400)
			self.write("Invalid set id")