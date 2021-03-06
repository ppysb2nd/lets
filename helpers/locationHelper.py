from json import loads
from urllib.request import urlopen

from common.log import logUtils as log


def getCountry(ip: str) -> str:
	"""
	Get country from IP address using geoip api

	:param ip: IP address
	:return: country code. XX if invalid.
	"""
	try:
		# Try to get country from Pikolo Aul's Go-Sanic ip API
		result = loads(urlopen(f'https://ip.zxq.co/{ip}', timeout=3).read().decode())["country"]
		return result.upper()
	except:
		log.error("Error in get country")
		return "XX"
