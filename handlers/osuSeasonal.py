import tornado.gen, tornado.web
from common.web import requestsManager

class handler(requestsManager.asyncRequestHandler):
    @tornado.web.asynchronous
    @tornado.gen.engine
    def asyncGet(self):
        self.write('''[
            "http://sb"
            ]'''.replace('/', '\/'))
