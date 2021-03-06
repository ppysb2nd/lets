import tornado.gen
import tornado.web

from typing import List, Optional
from common.sentry import sentry
from common.web import requestsManager
from constants import exceptions
from common.ripple import userUtils
from common.log import logUtils as log

class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/lastfm.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):

		if not requestsManager.checkArguments(self.request.arguments, ('us', 'ha', 'b')):
			self.write('Not yet')
			return

		username: Optional[str] = self.get_argument("us", None)
		password: Optional[str] = self.get_argument("ha", None)

		userID: int = userUtils.getID(username)

		if not userUtils.checkLogin(userID, password, self.getRequestIP()):
			self.write("Not yet")
			return

		# Get beatmap_id™ argument
		b = self.get_argument("b", None)

		# Flags sent back by the client.
		# a1   - osu run with -ld
		# a2   - osu has a console open
		# a4   - osu has extra threads while loading
		# a8   - run osu exe is hqosu
		# a16  - second check for hqosu exe if first fails
		# a32  - checks if osu has special launch settings in registry
		# a64  - AQN is loaded (already fixed by rumoi)
		# a128 - AQN is loaded (already fixed by rumoi)
		# a256 - notify_1 ran while out of editor (AQN sound on program open) (already fixed by rumoi)

		if b[0] == 'a' and not userUtils.checkDelayBan(userID) and not userUtils.isRestricted(userID):
			flags: int = int(''.join([n for n in b if n.isdigit()]))
			if flags == 4: return # Only extra threads running (could be PP calc).

			a: List[str] = []
			if flags & 1: a.append("[1] osu! run with -ld")
			if flags & 2: a.append("[2] osu! has a console open")
			if flags & 4: a.append("[4] osu! has extra threads running")
			if flags & 8: a.append("[8] osu! is hqosu! (check #1)")
			if flags & 16: a.append("[16] osu! is hqosu! (check #2)")
			if flags & 32: a.append("[32] osu! has special launch settings in registry")
			if flags & 64: a.append("[64] AQN is loaded (check #1)")
			if flags & 128: a.append("[128] AQN is loaded (check #2)")
			if flags & 256: a.append("[256] notify_1 was run while out of the editor (AQN sound on program open)")
			readable: str = '\n'.join(a)

			# Enqueue the users restriction.
			if flags not in (32, 36):
				userUtils.setDelayBan(userID, True)

				# Send our webhook to #lastfm-primary in discord.
				log.warning(f'[{username}](https://akatsuki.pw/u/{userID}) sent lastfm flags: **{b}**.\n\n**Breakdown**\n{readable}\n\n**[IP Matches](http://old.akatsuki.pw/index.php?p=136&uid={userID})**', 'lastfm')
			else:
				# Send our webhook to #lastfm-secondary in discord.
				log.warning(f'[{username}](https://akatsuki.pw/u/{userID}) sent lastfm flags: **{b}**.\n\n**Breakdown**\n{readable}\n\n**[IP Matches](http://old.akatsuki.pw/index.php?p=136&uid={userID})**', 'lastfm_secondary')

		self.write("Not yet")
