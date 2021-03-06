from common.log import logUtils as log


class invalidArgumentsException(Exception):
	def __init__(self, handler):
		log.warning(f'{handler} - Invalid arguments.')

class loginFailedException(Exception):
	def __init__(self, handler, who):
		log.warning(f"{handler} - {who}'s login failed.")

class userBannedException(Exception):
	def __init__(self, handler, who):
		log.warning(f'{handler} - {who} is banned.')

class userLockedException(Exception):
	def __init__(self, handler, who):
		log.warning(f'{handler} - {who} is locked.')

class noBanchoSessionException(Exception):
	def __init__(self, handler, who, ip):
		log.warning(f'{handler} - {who} has tried to submit a score from {ip} without an active bancho session from that ip. If this happens often, {who} is trying to use a score submitter.', 'bunker')

class osuApiFailException(Exception):
	def __init__(self, handler):
		log.warning(f'{handler} - Invalid data from osu!api.')

class fileNotFoundException(Exception):
	def __init__(self, handler, f):
		log.warning(f'{handler} - File not found ({f}).')

class invalidBeatmapException(Exception):
	pass

class unsupportedGameModeException(Exception):
	pass

class beatmapTooLongException(Exception):
	def __init__(self, handler):
		log.warning(f'{handler} - Requested beatmap is too long.')

class noAPIDataError(Exception):
	pass

class scoreNotFoundError(Exception):
	pass

class ppCalcException(Exception):
	def __init__(self, exception):
		self.exception = exception
