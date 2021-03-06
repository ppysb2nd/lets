import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from objects import glob
from common.sentry import sentry

MODULE_NAME = "bancho_connect"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/bancho_connect.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		try:
			# Get request ip
			ip = self.getRequestIP()

			# Argument check
			if not requestsManager.checkArguments(self.request.arguments, ["u", "h"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get user ID
			username = self.get_argument("u")
			userID = userUtils.getID(username)
			if not userID:
				raise exceptions.loginFailedException(MODULE_NAME, username)

			# Check login
			log.info(f"{username} ({userID}) wants to connect")
			if not userUtils.checkLogin(userID, self.get_argument("h"), ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)

			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)

			# Lock check
			if userUtils.isLocked(userID):
				raise exceptions.userLockedException(MODULE_NAME, username)

			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# Get country and output it
			self.write(glob.db.fetch("SELECT country FROM users_stats WHERE id = %s", [userID])["country"])
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass\n")
		except exceptions.userBannedException:
			pass
		except exceptions.userLockedException:
			pass
