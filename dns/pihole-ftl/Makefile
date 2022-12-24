PORTNAME=	pihole-ftl
PORTVERSION=	0.1
PORTREVISION=	1
CATEGORIES=	dns
WWW=		https://github.com/exeba/FTL

MAINTAINER=	no-one@FreeBSD.org
COMMENT=	Network-wide Ad Blocking

LICENSE=	MIT

USE_GITHUB=	yes
GH_ACCOUNT=	exeba
GH_PROJECT=	FTL
GH_TAGNAME=	2fd725f221558ad4dc3cae79d47ee467c6c0db92

USES=		cmake
RUN_DEPENDS=	bash:shells/bash sudo:security/sudo dig:dns/bind-tools sqlite3:databases/sqlite3
LIB_DEPENDS=	libnettle.so:security/nettle libidn.so:dns/libidn libreadline.so:devel/readline

USERS=	bind
GROUPS=	bind

DATADIR?=	${PREFIX}/share/pihole
ETCDIR?=	${PREFIX}/etc/pihole

USE_RC_SUBR=	pihole-FTL

SUB_FILES=	pkg-message

DO_MAKE_BUILD=	cmake --build . -- ${_MAKE_JOBS} 

BUILD_WRKSRC=	${WRKSRC}/cmake

pre-build:
	mkdir -p ${BUILD_WRKSRC}
	cd ${BUILD_WRKSRC} && cmake ..

do-install:
	${INSTALL_PROGRAM} ${BUILD_WRKSRC}/pihole-FTL ${STAGEDIR}${PREFIX}/bin
	${INSTALL_SCRIPT} ${FILESDIR}/bin/pihole ${STAGEDIR}${PREFIX}/bin
	# TODO: ${INSTALL_MAN} ${WRKSRC}/pihole.1 ${STAGEDIR}${MAN1PREFIX}/man/man1
	@${MKDIR} ${STAGEDIR}${ETCDIR}
	${INSTALL_DATA} ${FILESDIR}/config/pihole-FTL.conf ${STAGEDIR}${ETCDIR}/pihole-FTL.conf.sample
	${INSTALL_DATA} ${FILESDIR}/config/setupVars.conf ${STAGEDIR}${ETCDIR}/setupVars.conf.sample
	${INSTALL_DATA} ${FILESDIR}/config/dns-servers.conf ${STAGEDIR}${ETCDIR}/dns-servers.conf.sample
	${INSTALL_DATA} ${FILESDIR}/config/adlists.list ${STAGEDIR}${ETCDIR}/adlists.list.sample
	@${MKDIR} ${STAGEDIR}${DATADIR}/templates
	${INSTALL_DATA} ${FILESDIR}/templates/gravity.db.sql ${STAGEDIR}${DATADIR}/templates/gravity.db.sql
	${INSTALL_DATA} ${FILESDIR}/templates/gravity_copy.sql ${STAGEDIR}${DATADIR}/templates/gravity_copy.sql
	@${MKDIR} ${STAGEDIR}${DATADIR}/scripts
	${INSTALL_DATA} ${FILESDIR}/scripts/COL_TABLE ${STAGEDIR}${DATADIR}/scripts/COL_TABLE
	${INSTALL_SCRIPT} ${FILESDIR}/scripts/gravity.sh ${STAGEDIR}${DATADIR}/scripts/gravity.sh
	${INSTALL_DATA} ${FILESDIR}/scripts/utils.sh ${STAGEDIR}${DATADIR}/scripts/utils.sh
	@${MKDIR} ${STAGEDIR}${DATADIR}/scripts/database_migration
	cd ${FILESDIR}/scripts && ${COPYTREE_SHARE} database_migration ${STAGEDIR}${DATADIR}/scripts

.include <bsd.port.mk>
