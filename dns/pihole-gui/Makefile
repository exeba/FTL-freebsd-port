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
GH_TAGNAME=	606ed2bc407b0cb5a768a7e58656d883c2a174c0

DATADIR?=	${PREFIX}/share/pihole

SUB_FILES=	pkg-message

NO_BUILD=	yes

do-install:
	@${MKDIR} ${WWWDIR}
	cd ${WRKSRC} && ${COPYTREE_SHARE} . ${WWWDIR}
	@${MKDIR} ${EXAMPLESDIR}
	${INSTALL_DATA} ${FILESDIR}/examples/apache24-pihole-gui.conf ${EXAMPLESDIR}/apache24-pihole-gui.conf

.include <bsd.port.mk>
