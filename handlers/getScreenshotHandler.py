from os import path

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.web import requestsManager
from constants import exceptions
from objects import glob
from common.sentry import sentry

MODULE_NAME = "get_screenshot"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /ss/
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self, screenshotID = None):
		try:
			# Make sure the screenshot exists
			if not screenshotID or not path.isfile("/home/akatsuki/screenshots/{}".format(screenshotID)):
				raise exceptions.fileNotFoundException(MODULE_NAME, screenshotID)

			# Read screenshot
			with open("/home/akatsuki/screenshots/{}".format(screenshotID), "rb") as f:
				data = f.read()

			# Display screenshot
			self.write(data)
			self.set_header("Content-type", "image/png")
			self.set_header("Content-length", len(data))
		except exceptions.fileNotFoundException:
			self.set_status(404)
