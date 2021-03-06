from json import dumps

from common.web import requestsManager

class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /api/v1/status
	"""
	def asyncGet(self, uri):
		self.write(dumps({"status": 200, "server_status": 1}))
