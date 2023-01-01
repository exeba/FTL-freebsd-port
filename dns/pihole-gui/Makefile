PORTNAME=	pihole-gui
PORTVERSION=	0.1
PORTREVISION=	1
CATEGORIES=	dns
WWW=		https://github.com/exeba/AdminLTE

MAINTAINER=	no-one@FreeBSD.org
COMMENT=	Network-wide Ad Blocking

LICENSE=	MIT

USE_GITHUB=	yes
GH_ACCOUNT=	exeba
GH_PROJECT=	AdminLTE
GH_TAGNAME=	722f96512b40e7a1e49d77d83268be66de78c2ae

USES=           php
USE_PHP=        session sqlite3 mbstring

DATADIR?=	${PREFIX}/share/pihole

SUB_FILES=	pkg-message

NO_BUILD=	yes

do-install:
	@${MKDIR} ${WWWDIR}
	cd ${WRKSRC} && ${COPYTREE_SHARE} . ${WWWDIR}
	@${MKDIR} ${EXAMPLESDIR}
	${INSTALL_DATA} ${FILESDIR}/examples/apache24-pihole-gui.conf ${EXAMPLESDIR}/apache24-pihole-gui.conf
	${INSTALL_DATA} ${FILESDIR}/examples/sudoers.d-pihole-gui ${EXAMPLESDIR}/sudoers.d-pihole-gui

.include <bsd.port.mk>
