from typing import Any, Optional, List
from time import time

import tornado.gen
import tornado.web

from objects import beatmap
from objects import scoreboard
from objects import relaxboard
from common.constants import privileges
from common.constants import mods
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from objects import glob
from common.sentry import sentry

MODULE_NAME = "get_scores"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-osz2-getscores.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		try:
			start_time: float = time()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# TODO: Maintenance check

			# Check required arguments
			if not requestsManager.checkArguments(self.request.arguments, ["c", "f", "i", "m", "us", "v", "vv", "mods"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# GET parameters
			md5: Optional[str] = self.get_argument("c", None)
			beatmapSetID: int = int(self.get_argument("i", 0))
			gameMode: int = int(self.get_argument("m", 0))
			username: Optional[str] = self.get_argument("us", None)
			scoreboardType = int(self.get_argument("v", 0))
			scoreboardVersion = int(self.get_argument("vv", 0))
			score_mods = int(self.get_argument("mods", 0))

			# Login and ban check
			userID: int = userUtils.getID(username)
			if not userID:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
			if not userUtils.checkLogin(userID, self.get_argument("ha", ''), self.getRequestIP()):
				raise exceptions.loginFailedException(MODULE_NAME, username)

			try: # Already know its a valid login.
				if scoreboardVersion < 4 and not userUtils.checkDelayBan(userID) and not userUtils.isRestricted(userID):
					log.warning(f"**[{username}](https://akatsuki.pw/{'rx/' if score_mods & mods.RELAX else ''}u/{userID}) has signed in using a custom client.**", "custom_client")
					userUtils.setDelayBan(userID, True)
			except:
				pass

			# Scoreboard type
			country: bool = False
			friends: bool = False
			modsFilter: int = -1

			if scoreboardType == 4: # Country leaderboard
				country = True
			elif scoreboardType == 2: # Mods leaderboard, replace mods (-1, every mod) with "mods" GET parameters
				modsFilter = score_mods
			elif scoreboardType == 3 and userUtils.getPrivileges(userID) & privileges.USER_DONOR: # Friends leaderboard
				friends = True

			# Console output
			#fileNameShort = fileName[:48]+"..." if len(fileName) > 48 else fileName[:-4]
			#log.info("[{}] Requested beatmap {}".format("RELAX" if scoreboardType == 1 and mods & 128 else "VANILLA", fileNameShort))

			# Create beatmap object and set its data
			bmap: beatmap.beatmap = beatmap.beatmap(md5, beatmapSetID, gameMode)

			if score_mods & mods.RELAX:
				glob.redis.publish("peppy:update_rxcached_stats", userID)
				sboard = relaxboard.scoreboard(username, gameMode, bmap, setScores=True, country=country, mods=modsFilter, friends=friends)
			else:
				glob.redis.publish("peppy:update_cached_stats", userID)
				sboard = scoreboard.scoreboard(username, gameMode, bmap, setScores=True, country=country, mods=modsFilter, friends=friends)

			# Data to return
			data: List[Any] = []
			data.append(bmap.getData(sboard.totalScores, scoreboardVersion))
			data.append(sboard.getScoresData())
			self.write(''.join(data))

			# Datadog stats
			glob.dog.increment(f'{glob.DATADOG_PREFIX}.served_leaderboards')

			log.info(f'Leaderboard took {round(1000 * (time() - start_time))}ms.')
		except exceptions.invalidArgumentsException:
			self.write("error: meme")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.loginFailedException:
			self.write("error: pass")
