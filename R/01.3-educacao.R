#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
###### 0.1.3 Leitura e filtro de dados do censo escolar

## info:
# dados originais fornecidos pelo INEP


# carregar bibliotecas
source('./R/fun/setup.R')




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 1. Ler dados do INEP novos ------------------------------------------------------------------

escolas <- fread("../data-raw/censo_escolar/ESCOLAS_APLI_CATALOGO_ABR2019.csv")


# filtrar so dos nossos municipios
escolas_filt <- escolas %>%
  filter(CO_MUNICIPIO %in% munis_df$code_muni) %>%
  filter(CATEGORIA_ADMINISTRATIVA == "Pública") %>%
  rename(lon = LONGITUDE, lat = LATITUDE)


# excluir escolas paralisadas
escolas_filt <- escolas_filt %>% filter(RESTRICAO_ATENDIMENTO != "ESCOLA PARALISADA")


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 2. Identificar CENSO ESCOLAR com lat/long problematicos

# A - poucos digitos
# B - fora dos limites do municipio
# C - com coordenadas NA


# qual o nivel de precisao das coordenadas deve ser aceito?
# 0.01 = 1113.2 m
# 0.001 = 111.32 m
# 0.0001 = 11.132 m
# 0.00001 = 1.1132 m


# A) Numero de digitos de lat/long apos ponto
setDT(escolas_filt)[, ndigitos := nchar(sub("(-\\d+)\\.(\\d+)", "\\2", lat))]
A_estbs_pouco_digito <- escolas_filt[ ndigitos <=2,]


# B) fora dos limites do municipio

# carrega shapes
shps <- purrr::map_dfr(dir("../data-raw/municipios/", recursive = TRUE, full.names = TRUE), read_rds) %>% 
  as_tibble() %>% 
  st_sf(crs = 4326)

# convert para sf
censoescolar2019_df_coords_fixed_df <- escolas_filt[!(is.na(lat))] %>% 
  st_as_sf( coords = c('lon', 'lat'), crs = 4326)

temp_intersect <- sf::st_join(censoescolar2019_df_coords_fixed_df, shps)

# escolas que cairam fora de algum municipio
B_muni_fora <- subset(temp_intersect, is.na(name_muni))

# juntar todos municipios com erro de lat/lon
munis_problema1 <- subset(escolas_filt, CO_ENTIDADE %in% A_estbs_pouco_digito$CO_ENTIDADE ) 
munis_problema2 <- subset(escolas_filt, CO_ENTIDADE %in% B_muni_fora$CO_ENTIDADE )
munis_problema3 <- escolas_filt[ is.na(lat), ]
munis_problema <- rbind(munis_problema1, munis_problema2, munis_problema3)
munis_problema <- dplyr::distinct(munis_problema, CO_ENTIDADE, .keep_all=T) # remove duplicates


# ajeitar enderecos para o galileo
# quebrar a string de endereco nos pontos
# colunas: logradouro, cidade, bairro, cep, uf
teste <- munis_problema %>%
  separate(ENDERECO, c("logradouro", "bairro", "cep"), "\\.") %>%
  # tirar espacos em branco
  mutate(bairro = trimws(bairro, which = "both")) %>%
  # se a coluna do bairro for vazia, significa que o endereco nao tem bairro. transpor essa coluna
  # para a coluna do cep
  mutate(cep = ifelse(grepl("^\\d{5}.*", bairro), bairro, cep)) %>%
  # e apagar os bairros com cep
  mutate(bairro = ifelse(grepl("^\\d{5}.*", bairro), "", bairro)) %>%
  # agora separar so o cep
  mutate(cep1 = str_extract(cep, "\\d{5}-\\d{3}")) %>%
  # extrair cidade e uf
  mutate(cidade_uf = gsub("(\\d{5}-\\d{3}) (.*)$", "\\2", cep)) %>%
  # tirar espacos em branco
  mutate(cidade_uf = trimws(cidade_uf, "both")) %>%
  # separar cidade e uf
  separate(cidade_uf, c("cidade", "uf"), "-",  remove = TRUE) %>%
  mutate(cidade = trimws(cidade, "both")) %>%
  mutate(uf = trimws(uf, "both")) %>%
  # selecionar colunas
  select(CO_ENTIDADE, rua = logradouro, cidade, bairro, cep = cep1, uf)

# salvar input para o galileo
write_delim(teste, "../data-raw/censo_escolar/escolas_2019_input_galileo.csv", delim = ";")  
  



### RODAR GALILEO--------------
# depois de rodar o galileo...

# abrir output do galileo
educacao_output_galileo <- fread("../data-raw/censo_escolar/escolas_2019_output_galileo.csv") %>%
  # filtrar somente os maiores que 2 estrelas
  filter(PrecisionDepth %nin% c("1 Estrela", "2 Estrelas")) %>%
  # substituir virgula por ponto
  mutate(Latitude = str_replace(Latitude, ",", "\\.")) %>%
  mutate(Longitude = str_replace(Longitude, ",", "\\.")) %>%
  # selecionar colunas
  select(CO_ENTIDADE, lat = Latitude, lon = Longitude) %>%
  mutate(lon = as.numeric(lon),
         lat = as.numeric(lat))

# juntar com a base anterior completa para atualizar lat e lon q veio do Galileo
  setDT(escolas_filt)[educacao_output_galileo, on='CO_ENTIDADE', c('lat', 'lon') := list(i.lat, i.lon)]
  summary(escolas_filt$lon) # 149 NA's, mais nos valores de menos que 2 estrelas do galileo

# para esses, sera utilizado o geocode do google maps 




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 3. Recupera a info lat/long que falta usando google maps -----------------------------------------

# # Escolas com lat/long de baixa precisa (1 ou 2 digitos apos casa decimal)
# setDT(escolas_etapa)[, ndigitos := nchar(sub("(-\\d+)\\.(\\d+)", "\\2", lat))]
# lat_impreciso <- subset(escolas_etapa, ndigitos <=2)$CO_ENTIDADE
# escolas_lat_impreciso <- subset(escolas, CO_ENTIDADE %in% lat_impreciso)


# Escolas com lat/long missing  
CO_ENTIDADE_lat_missing <- subset(escolas_filt, is.na(lat))$CO_ENTIDADE
escolas_problema <- subset(escolas, CO_ENTIDADE %in% CO_ENTIDADE_lat_missing)

# lista de enderecom com problema
enderecos <- escolas_problema$ENDERECO

# registrar Google API Key
my_api <- data.table::fread("../data-raw/google_key.txt", header = F)
register_google(key = my_api$V1)

# geocode
coordenadas_google <- lapply(X=enderecos, ggmap::geocode) %>% rbindlist()

# Link escolas com lat lon do geocode
escolas_lat_missing_geocoded <- cbind(escolas_problema, coordenadas_google)

summary(escolas_lat_missing_geocoded$lat) # Google nao encontrou 3 casos

# atualiza lat lon a partir de google geocode
escolas_filt[, lat := as.numeric(lat)][, lon := as.numeric(lon)]
setDT(escolas_filt)[escolas_lat_missing_geocoded, on='CO_ENTIDADE', c('lat', 'lon') := list(i.lat, i.lon) ]

summary(escolas_filt$lat)


subset(escolas_filt, !is.na(lat)) %>%
  to_spatial() %>%
  mapview()

# ainda ha escolas mal georreferenciadas!
# identificar essas escolas e separa-las
# convert para sf
escolas_google_mal_geo <- escolas_filt %>%
  filter(!is.na(lat)) %>% 
  st_as_sf(coords = c('lon', 'lat'), crs = 4326) %>%
  sf::st_join(shps) %>%
  # escolas que cairam fora de algum municipio, a serem georreferenciadas na unha
  filter(is.na(name_muni)) %>%
  select(CO_ENTIDADE, ENDERECO)

mapview(escolas_google_mal_geo)

# Retorna somente os ceps dos que deram errado para jogar no google API
somente_ceps <- gsub("(^.*)(\\d{5}-\\d{3}.*$)", "\\2", escolas_google_mal_geo$ENDERECO)

# consulta google api
coordenadas_google_cep <- lapply(X=somente_ceps, ggmap::geocode) %>% rbindlist()


# atualiza lat lon a partir de google geocode
escolas_google_bom_geo <- cbind(as.data.frame(escolas_google_mal_geo), coordenadas_google_cep)
setDT(escolas_filt)[escolas_google_bom_geo, on='CO_ENTIDADE', c('lat', 'lon') := list(i.lat, i.lon) ]

subset(escolas_filt, !is.na(lat)) %>%
  to_spatial() %>%
  mapview()




# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 4. trazer escolas do censo escolar 2018 ----------------------------------------------------------
  
  # O Censo escolar traz dado codificada da etapa de ensino. Para as informacoes missing, a gente usa
  # a info de etapa de ensino informada no dado do INEP geo

# colunas de interesse: 
colunas <- c("CO_ENTIDADE", "NO_ENTIDADE",
             "IN_COMUM_CRECHE", "IN_COMUM_PRE", 
             "IN_COMUM_FUND_AI", "IN_COMUM_FUND_AF", 
             "IN_COMUM_MEDIO_MEDIO", "IN_COMUM_MEDIO_NORMAL",
             "IN_ESP_EXCLUSIVA_CRECHE", "IN_ESP_EXCLUSIVA_PRE", 
             "IN_COMUM_MEDIO_INTEGRADO", "IN_PROFISSIONALIZANTE",
             "IN_ESP_EXCLUSIVA_FUND_AI", "IN_ESP_EXCLUSIVA_FUND_AF",
             "IN_ESP_EXCLUSIVA_MEDIO_MEDIO", "IN_ESP_EXCLUSIVA_MEDIO_INTEGR",
             "IN_ESP_EXCLUSIVA_MEDIO_NORMAL","IN_COMUM_EJA_MEDIO","IN_COMUM_EJA_PROF",
             "IN_ESP_EXCLUSIVA_EJA_MEDIO","IN_ESP_EXCLUSIVA_EJA_PROF","IN_COMUM_PROF",
             "IN_ESP_EXCLUSIVA_PROF","IN_COMUM_EJA_FUND","IN_ESP_EXCLUSIVA_EJA_FUND")



# abrir
escolas_censo <- fread("../data-raw/censo_escolar/censo_escolar_escolas_2018.CSV", select=colunas ) %>%
  # selecionar escolas
  filter(CO_ENTIDADE %in% escolas_filt$CO_ENTIDADE) %>%
  # identificar o tipo de ensino em cada escola
  mutate(mat_infantil = ifelse(IN_COMUM_CRECHE == 1 | 
                                 IN_COMUM_PRE == 1 |
                               IN_ESP_EXCLUSIVA_CRECHE == 1 |
                               IN_ESP_EXCLUSIVA_PRE ==1, 1, 0)) %>%
  
  mutate(mat_fundamental = ifelse(IN_COMUM_FUND_AI == 1 | 
                                    IN_COMUM_FUND_AF == 1 |
                                    IN_ESP_EXCLUSIVA_FUND_AI ==1 |
                                    IN_ESP_EXCLUSIVA_FUND_AF ==1 |
                                    IN_COMUM_EJA_FUND ==1 |
                                    IN_ESP_EXCLUSIVA_EJA_FUND ==1, 1, 0)) %>%
  mutate(mat_medio = ifelse(IN_COMUM_MEDIO_MEDIO == 1 |
                              IN_COMUM_MEDIO_NORMAL == 1 |
                              IN_COMUM_MEDIO_INTEGRADO ==1 |
                              IN_PROFISSIONALIZANTE ==1 |
                              IN_ESP_EXCLUSIVA_MEDIO_MEDIO ==1 |
                              IN_ESP_EXCLUSIVA_MEDIO_INTEGR ==1 |
                              IN_ESP_EXCLUSIVA_MEDIO_NORMAL ==1 |
                              IN_COMUM_EJA_MEDIO ==1 |
                              IN_COMUM_EJA_PROF ==1 |
                              IN_ESP_EXCLUSIVA_EJA_MEDIO ==1 |
                              IN_ESP_EXCLUSIVA_EJA_PROF ==1 |
                              IN_COMUM_PROF ==1 |
                              IN_ESP_EXCLUSIVA_PROF ==1, 1, 0)) %>%
  # Selecionar variaveis
  select(CO_ENTIDADE, NO_ENTIDADE, mat_infantil, mat_fundamental, mat_medio)


# talvez tenham q remover escolas priosionais
# ?

# 195 escolas sem informacao alguma
setDT(escolas_censo)[, test := sum(mat_infantil, mat_fundamental, mat_medio), by=CO_ENTIDADE]
table(escolas_censo$test)


# juntar com a base nova
escolas_etapa <- escolas_filt %>%
  left_join(escolas_censo, by = c("CO_ENTIDADE")) # %>%
  # filter(!is.na(lon)) %>%
  # filter(!is.na(mat_infantil))

# # Quantas escolas estao com dados missing (lat/long e nivel de ensino) por municipio
# setDT(escolas_etapa)[, .( total= .N,
#                           lat_miss = sum(is.na(lat)),
#                           lat_miss_p = 100*sum(is.na(lat) /.N),
#                           ensino_miss = sum(is.na(mat_infantil)),
#                           ensino_miss_p = 100*sum(is.na(mat_infantil))/.N), by=CO_MUNICIPIO ][order(-lat_miss_p)]


table(escolas_etapa$mat_infantil, useNA = "always")
table(escolas_etapa$mat_fundamental, useNA = "always")
table(escolas_etapa$mat_medio, useNA = "always")

# # Recupera informacao de etapa de ensino do censo escolar informado no dado enviado pelo INEP geo
#   escolas_etapa <- left_join(escolas_etapa, select(escolas, CO_ENTIDADE, OFERTA_ETAPA_MODALIDADE), by='CO_ENTIDADE')

  # tests
  # subset(test,mat_infantil !=1 &  mat_fundamental !=1 & mat_medio ==1 )$OFERTA_ETAPA_MODALIDADE %>% table %>% View()
  
# codifica etapa de ensino pela string
setDT(escolas_etapa)[, mat_infantil := ifelse(is.na(mat_infantil) & OFERTA_ETAPA_MODALIDADE %like% 'Creche|Pré-escola', 1, 
                                              mat_infantil)]
setDT(escolas_etapa)[, mat_fundamental := ifelse(is.na(mat_fundamental) & OFERTA_ETAPA_MODALIDADE %like% 'Ensino Fundamental', 1, 
                                                 mat_fundamental)]
setDT(escolas_etapa)[, mat_medio := ifelse(is.na(mat_medio) & OFERTA_ETAPA_MODALIDADE %like% "Ensino Médio|nível Médio|Curso Profissional|Curso Técnico", 1, 
                                           mat_medio)]
  

# restricoes em tipo de esino
escolas_etapa[ test ==0]$RESTRICAO_ATENDIMENTO  %>% table
table(escolas_etapa$RESTRICAO_ATENDIMENTO)


table(escolas_etapa$mat_infantil, useNA = "always")
table(escolas_etapa$mat_fundamental, useNA = "always")
table(escolas_etapa$mat_medio, useNA = "always")



# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 5. salvar ----------------------------------------------------------------------------------------

# salvar
  write_rds(escolas_etapa, "../data/censo_escolar/educacao_inep_2019.rds")

